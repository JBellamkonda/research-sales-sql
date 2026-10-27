/* ============================================================
   STEP 1: Task-level subquery (for activity logic)
   ============================================================ */
WITH Activity_Base AS (
    SELECT
        o.ID AS Opportunity_ID,
        o.NAME AS Opportunity_Name,
        o.LASTACTIVITYDATE AS Opportunity_LastActivityDate,
        o.STAGENAME AS SFDC_Stage, 
        o.MQL_DATE__C AS MQL_DATE,

        -- ✅ FIX: add Task_ID
        tsk.ID AS Task_ID,

        tsk.TASKSUBTYPE,
        COALESCE(tsk.TYPE, tsk.TASKSUBTYPE) AS Task_Type,
        tsk.ACTIVITYDATE,

        ROW_NUMBER() OVER (
            PARTITION BY o.ID
            ORDER BY tsk.ACTIVITYDATE DESC, tsk.CREATEDDATE DESC
        ) AS rn_latest,

        -- Stage fields (unchanged)
        o.PROSPECT_STAGE_DURATION_DAYS__C AS PROSPECT_STAGE_DURATION,
        o.BUYING_ALIGNMENT_STAGE_DURATION_DAYS__C AS BUYING_ALIGNMENT_STAGE_DURATION_DAYS,
        o.ESTABLISH_VALUE_STAGE_DURATION_DAYS__C AS ESTABLISH_VALUE_STAGE_DURATION_DAYS,
        o.DECISION_DUE_STAGE_DURATION_DAYS__C AS DECISION_DUE_STAGE_DURATION_DAYS,
        o.EVALUATION_STAGE_DURATION_DAYS__C AS EVALUATION_STAGE_DURATION_DAYS,
        o.WON_STAGE_DURATION_DAYS__C AS WON_STAGE_DURATION_DAYS,

        -- Calculated fields
        CASE
            WHEN o.ISCLOSED THEN DATE_DIFF(DATE(o.CLOSEDATE), DATE(o.CREATEDDATE), DAY) + 1
            ELSE DATE_DIFF(CURRENT_DATE(), DATE(o.CREATEDDATE), DAY) + 1
        END AS Days_Open,

        CASE
            WHEN o.ISCLOSED THEN 0
            WHEN DATE(o.CLOSEDATE) < CURRENT_DATE() THEN NULL
            ELSE DATE_DIFF(DATE(o.CLOSEDATE), CURRENT_DATE(), DAY)
        END AS Days_to_Close,

        DATE_DIFF(
            CURRENT_DATE(),
            DATE(COALESCE(o.LASTSTAGECHANGEDATE, o.CREATEDDATE)),
            DAY
        ) + 1 AS Stage_Duration_Days,

        -- Activity fields
        o.OPEN_ACTIVITIES_COUNT__C AS OPEN_ACTIVITIES_COUNT,
        o.LAST_OPEN_ACTIVITY_DATE__C AS LAST_OPEN_ACTIVITY_DATE,
        o.COMPLETED_ACTIVITIES_COUNT__C AS COMPLETED_ACTIVITIES_COUNT,
        o.LAST_COMPLETED_ACTIVITY_DATE__C AS LAST_COMPLETED_ACTIVITY_DATE,
        o.LAST_ENGAGEMENT_DATE__C AS LAST_ENGAGEMENT_DATE

    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_TASK` tsk
        ON tsk.WHATID = o.ID
        AND tsk.ISDELETED = FALSE

    WHERE
        EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
        AND o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research', 'Corporate Sales')
),

/* ============================================================
   STEP 2: Campaign Influence Base (classification logic)
   ============================================================ */
Campaign_Base AS (
    SELECT
        ci.OPPORTUNITY__C AS Opportunity_ID,
        ci.CAMPAIGN__C AS Campaign_ID,
        upc.NAME AS UL_Parent_Name,

        CASE
            WHEN upc.NAME IN (
                'Research & Learning Marketing Master FY25',
                'Research & Learning Marketing Master FY26'
            ) THEN 'Marketing'
            WHEN upc.NAME IN (
                'Research Customer Education FY25',
                'Research Customer Education FY26'
            ) THEN 'Customer Education'
            WHEN upc.NAME = 'Research Revenue Strategy & Operations'
                THEN 'RevOps'
            ELSE 'Other'
        END AS Campaign_Category

    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN_INFLUENCE` ci
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` c
        ON ci.CAMPAIGN__C = c.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` upc
        ON upc.ID = c.ULTIMATE_PARENT_ID_STRING__C

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
        ON o.ID = ci.OPPORTUNITY__C

    WHERE
        -- ✅ FIX: TIMESTAMP → CAST to DATE before DATE_ADD with MONTH
        EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
),

Campaign_Summary AS (
    SELECT
        Opportunity_ID,
        COUNT(DISTINCT IF(Campaign_Category = 'Marketing', Campaign_ID, NULL)) AS Marketing_Campaign_Count,
        COUNT(DISTINCT IF(Campaign_Category = 'Customer Education', Campaign_ID, NULL)) AS CustEdu_Campaign_Count,
        COUNT(DISTINCT IF(Campaign_Category = 'RevOps', Campaign_ID, NULL)) AS RevOps_Campaign_Count
    FROM Campaign_Base
    GROUP BY Opportunity_ID
),

Customer_Success_Summary AS (

    SELECT
        OPPORTUNITY_ID,
        COUNT(DISTINCT CTA_GSID) AS CustomerSuccess_Influence_Count

    FROM `prd-wiley-data.EDW_RESEARCH.GAINSIGHT_CSQL`

    WHERE OPPORTUNITY_ID IS NOT NULL

    GROUP BY OPPORTUNITY_ID
)


/* ============================================================
   STEP 4: Final Opportunity Activity Summary
   ============================================================ */
SELECT
    a.Opportunity_ID,
    a.Opportunity_Name,
    a.Opportunity_LastActivityDate,
    a.SFDC_STAGE,

    -- ✅ FIXED COUNTS
    COUNT(CASE WHEN a.TASKSUBTYPE = 'Email' THEN a.Task_ID END) AS Email_Count,
    COUNT(CASE WHEN a.TASKSUBTYPE = 'Call'  THEN a.Task_ID END) AS Call_Count,
    COUNT(CASE WHEN a.TASKSUBTYPE = 'Task'  THEN a.Task_ID END) AS Task_Count,

    -- ✅ MAIN FIX
    COUNT(a.Task_ID) AS Total_ActivityCount,

    /* =====================
       Latest overall activity
       ===================== */
    MAX(CASE WHEN a.rn_latest = 1 THEN a.TASKSUBTYPE END)          AS Latest_Task_Subtype,
    MAX(CASE WHEN a.rn_latest = 1 THEN a.Task_Type   END)          AS Latest_Task_Type,

    /* Closest FUTURE subtype (aligned with date) */
    MAX(
        CASE
            WHEN CAST(a.ACTIVITYDATE AS DATE) = (
                SELECT MIN(CAST(a2.ACTIVITYDATE AS DATE))
                FROM Activity_Base a2
                WHERE a2.Opportunity_ID = a.Opportunity_ID
                AND CAST(a2.ACTIVITYDATE AS DATE) > CURRENT_DATE()
            )
            THEN a.Task_Type
        END
    )                                                               AS Closest_Future_Task_Type,

    /* =====================
       Aggregated activity types
       ===================== */
    -- ✅ LISTAGG → STRING_AGG in BigQuery
    STRING_AGG(DISTINCT a.TASKSUBTYPE, ', '
        ORDER BY a.TASKSUBTYPE)                                     AS Task_Types,

    /* =====================
       Latest (absolute) dates
       ===================== */
    -- ✅ TO_DATE(MAX(...)) → CAST(MAX(...) AS DATE) for TIMESTAMP columns
    CAST(MAX(CASE WHEN a.TASKSUBTYPE = 'Email' THEN a.ACTIVITYDATE END) AS DATE) AS Latest_Email_Date,
    CAST(MAX(CASE WHEN a.TASKSUBTYPE = 'Call'  THEN a.ACTIVITYDATE END) AS DATE) AS Latest_Call_Date,
    CAST(MAX(CASE WHEN a.TASKSUBTYPE = 'Task'  THEN a.ACTIVITYDATE END) AS DATE) AS Latest_Task_Date,

    /* =====================
       Closest PAST dates
       ===================== */
    CAST(MAX(CASE
        WHEN a.TASKSUBTYPE = 'Email'
        AND CAST(a.ACTIVITYDATE AS DATE) < CURRENT_DATE()
        THEN a.ACTIVITYDATE END) AS DATE)                          AS Closest_Past_Email_Date,
    CAST(MAX(CASE
        WHEN a.TASKSUBTYPE = 'Call'
        AND CAST(a.ACTIVITYDATE AS DATE) < CURRENT_DATE()
        THEN a.ACTIVITYDATE END) AS DATE)                          AS Closest_Past_Call_Date,
    CAST(MAX(CASE
        WHEN a.TASKSUBTYPE = 'Task'
        AND CAST(a.ACTIVITYDATE AS DATE) < CURRENT_DATE()
        THEN a.ACTIVITYDATE END) AS DATE)                          AS Closest_Past_Task_Date,

    /* =====================
       Closest FUTURE dates
       ===================== */
    CAST(MIN(CASE
        WHEN a.TASKSUBTYPE = 'Task'
        AND CAST(a.ACTIVITYDATE AS DATE) > CURRENT_DATE()
        THEN a.ACTIVITYDATE END) AS DATE)                          AS Closest_Future_Task_Date,


    /* =====================
   Campaign influence counts
   ===================== */

    COALESCE(cs.Marketing_Campaign_Count,0) AS Marketing_Campaign_Count,
    COALESCE(cs.CustEdu_Campaign_Count,0) AS CustEdu_Campaign_Count,
    COALESCE(cs.RevOps_Campaign_Count,0) AS RevOps_Campaign_Count,

    CASE
        WHEN COALESCE(cs.Marketing_Campaign_Count,0) > 0 THEN 'Yes'
        ELSE 'No'
    END AS Marketing_Influenced,

    CASE
        WHEN COALESCE(cs.CustEdu_Campaign_Count,0) > 0 THEN 'Yes'
        ELSE 'No'
    END AS CustEdu_Influenced,

    CASE
        WHEN COALESCE(cs.RevOps_Campaign_Count,0) > 0 THEN 'Yes'
        ELSE 'No'
    END AS RevOps_Influenced,

    CASE
        WHEN COALESCE(css.CustomerSuccess_Influence_Count,0) > 0 THEN 'Yes'
        ELSE 'No'
    END AS CustomerSuccess_Influenced,

    COALESCE(css.CustomerSuccess_Influence_Count,0)
        AS CustomerSuccess_Influence_Count,

    -- Lead Management Framework (LMF)
    CASE WHEN a.MQL_DATE IS NOT NULL THEN 1 ELSE 0 END AS LMF,    


    /* ═════════════════════════════════════════════════════════════════
       MOVED FROM DATA TABLE: Stage Duration Fields
       ═════════════════════════════════════════════════════════════════ */
    a.PROSPECT_STAGE_DURATION,
    a.BUYING_ALIGNMENT_STAGE_DURATION_DAYS,
    a.ESTABLISH_VALUE_STAGE_DURATION_DAYS,
    a.DECISION_DUE_STAGE_DURATION_DAYS,
    a.EVALUATION_STAGE_DURATION_DAYS,
    a.WON_STAGE_DURATION_DAYS,

    /* ═════════════════════════════════════════════════════════════════
       MOVED FROM DATA TABLE: Calculated Fields
       ═════════════════════════════════════════════════════════════════ */
    a.Days_Open,
    a.Days_to_Close,
    a.Stage_Duration_Days,

    /* ═════════════════════════════════════════════════════════════════
       MOVED FROM DATA TABLE: SFDC Activity Fields
       ═════════════════════════════════════════════════════════════════ */
    a.OPEN_ACTIVITIES_COUNT,
    a.LAST_OPEN_ACTIVITY_DATE,
    a.COMPLETED_ACTIVITIES_COUNT,
    a.LAST_COMPLETED_ACTIVITY_DATE,
    a.LAST_ENGAGEMENT_DATE

FROM Activity_Base a
LEFT JOIN Campaign_Summary cs
    ON a.Opportunity_ID = cs.Opportunity_ID
LEFT JOIN Customer_Success_Summary css
    ON a.Opportunity_ID = css.OPPORTUNITY_ID

-- WHERE a.Opportunity_ID = '006WQ00000QUhuzYAD'

GROUP BY
    a.Opportunity_ID,
    a.Opportunity_Name,
    a.Opportunity_LastActivityDate,
    a.SFDC_STAGE,
    a.MQL_DATE,
    cs.Marketing_Campaign_Count,
    cs.CustEdu_Campaign_Count,
    cs.RevOps_Campaign_Count,
    css.CustomerSuccess_Influence_Count,
    a.PROSPECT_STAGE_DURATION,
    a.BUYING_ALIGNMENT_STAGE_DURATION_DAYS,
    a.ESTABLISH_VALUE_STAGE_DURATION_DAYS,
    a.DECISION_DUE_STAGE_DURATION_DAYS,
    a.EVALUATION_STAGE_DURATION_DAYS,
    a.WON_STAGE_DURATION_DAYS,
    a.Days_Open,
    a.Days_to_Close,
    a.Stage_Duration_Days,
    a.OPEN_ACTIVITIES_COUNT,
    a.LAST_OPEN_ACTIVITY_DATE,
    a.COMPLETED_ACTIVITIES_COUNT,
    a.LAST_COMPLETED_ACTIVITY_DATE,
    a.LAST_ENGAGEMENT_DATE
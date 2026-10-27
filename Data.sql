-- =============================================================================
-- CS/IS Report — Data query (FINAL)
-- =============================================================================
-- ROOT CAUSE (confirmed): GAINSIGHT_CSQL.CREATED_DATE is a TIMESTAMP WITH TIME ZONE
--   (values like 2024-01-28T17:24:39-08:00 / 2026-08-01T01:19:43-07:00).
--   The Arrow connector reads it via DateTimeOffset(ticks, offset); the offset
--   arithmetic overflows the .NET DateTime ticks range -> "Ticks must be between..."
--   The VALUES are in range (2024–2026) — that's why clamping never helped.
--   FIX: wrap CREATED_DATE in DATE() to strip the timezone offset.
--
-- Other hardening retained:
--   • CLAMP OFH.OLDVALUE / OFH.NEWVALUE (field-history close dates) to 1990–2100.
--   • CLAMP Latest_Email/Call/Task_Date (TASK.ACTIVITYDATE range 1960–3036).
--   • SAFE_CAST on all string->date conversions.
--   • FX joins removed; USD_PRIORYEAR_AMT = CAST(NULL AS FLOAT64) placeholder.
--   • JULIE EXCEPTION: Julie Attrill's opps are all product family 'Standard'
--     (plus one with NULL family), which the query normally excludes. A targeted
--     exception now lets HER Standard/NULL-family opps through while keeping the
--     Standard/M3 exclusion for everyone else. (Pending Yen's confirmation.)
--   • Recommended: remove [Implementation="2.0"] from GoogleBigQuery.Database(...)
--     and keep Auto date/time OFF (Current File).
-- =============================================================================

WITH
Marketing AS (
    SELECT *
    FROM (
        SELECT
            CI.OPPORTUNITY__C,
            c.NAME,
            ROW_NUMBER() OVER (
                PARTITION BY o.ID
                ORDER BY c.LASTMODIFIEDDATE DESC
            ) AS ROW_NUMBER
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN_INFLUENCE` CI
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` c
            ON CI.CAMPAIGN__C = C.ID
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
            ON o.ID = CI.OPPORTUNITY__C
        WHERE
            EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
                >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 1
            AND c.LASTMODIFIEDDATE IS NOT NULL
    )
    WHERE ROW_NUMBER = 1
),
Opty AS (
    SELECT
        o.ID,
        oli.ID AS oliID,
        STRING_AGG(DISTINCT COALESCE(a.NAME, 'Unknown Agency'), '\n'
            ORDER BY COALESCE(a.NAME, 'Unknown Agency'))    AS Agencies,
        STRING_AGG(DISTINCT COALESCE(a.ID, 'UnknownID'), '\n'
            ORDER BY COALESCE(a.ID, 'UnknownID'))           AS Agency_Account_IDs
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_LINE_ITEM` oli
        ON oli.OPPORTUNITYID = o.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` a
        ON oli.AGENCY__C = a.ID
    WHERE
        o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research', 'Corporate Sales')
        AND oli.ISDELETED = FALSE
        AND EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 2
    GROUP BY o.ID, oliID
),
LastActivityCTE AS (
    SELECT
        o.LASTACTIVITYDATE,
        o.NAME,
        o.ID                                                    AS Opportunity_ID,
        tsk.TASKSUBTYPE,
        CASE WHEN tsk.TYPE IS NULL THEN tsk.TASKSUBTYPE ELSE tsk.TYPE END AS Task_Type,
        tsk.ACTIVITYDATE,
        ROW_NUMBER() OVER (
            PARTITION BY o.ID
            ORDER BY tsk.ACTIVITYDATE DESC, tsk.CREATEDDATE DESC
        ) AS ROW_NUMBER
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_TASK` tsk
        ON tsk.WHATID = o.ID
    WHERE
        EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
        AND o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research','Corporate Sales')
        AND tsk.ISDELETED = FALSE
),
-- All activity aggregations centralised here including Latest dates.
TaskCountsCTE AS (
    SELECT
        la.Opportunity_ID,
        COUNT(CASE WHEN la.TASKSUBTYPE = 'Email' THEN 1 END)             AS Email_Count,
        COUNT(CASE WHEN la.TASKSUBTYPE = 'Call'  THEN 1 END)             AS Call_Count,
        COUNT(CASE WHEN la.TASKSUBTYPE = 'Task'  THEN 1 END)             AS Task_Count,
        MAX(CASE WHEN la.ROW_NUMBER = 1 THEN la.TASKSUBTYPE END)         AS Latest_Task_Subtype,
        MAX(CASE WHEN la.ROW_NUMBER = 1 THEN la.Task_Type   END)         AS Latest_Task_Type,
        COUNT(la.Opportunity_ID)                                          AS Total_ActivityCount,
        STRING_AGG(DISTINCT la.TASKSUBTYPE, ', '
            ORDER BY la.TASKSUBTYPE)                                      AS Task_Types,
        -- ✅ CLAMP: only consider valid activity dates (TASK.ACTIVITYDATE range was 1960–3036)
        MAX(CASE
                WHEN la.TASKSUBTYPE = 'Email'
                 AND SAFE_CAST(la.ACTIVITYDATE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-12-31'
                THEN SAFE_CAST(la.ACTIVITYDATE AS DATE)
            END)                                                          AS Latest_Email_Date,
        MAX(CASE
                WHEN la.TASKSUBTYPE = 'Call'
                 AND SAFE_CAST(la.ACTIVITYDATE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-12-31'
                THEN SAFE_CAST(la.ACTIVITYDATE AS DATE)
            END)                                                          AS Latest_Call_Date,
        MAX(CASE
                WHEN la.TASKSUBTYPE = 'Task'
                 AND SAFE_CAST(la.ACTIVITYDATE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-12-31'
                THEN SAFE_CAST(la.ACTIVITYDATE AS DATE)
            END)                                                          AS Latest_Task_Date
    FROM LastActivityCTE la
    GROUP BY la.Opportunity_ID
),
Opportunity_Summary AS (
    SELECT
        a.ID                                AS ACCOUNTID,
        a.ULTIMATE_PARENT_ACCOUNT_ID18__C,
        MIN(CASE
            WHEN o.STAGENAME = 'Invoiced'
            THEN EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
        END)                                AS First_Invoice_FY
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` a
        ON o.ACCOUNTID = a.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` u
        ON o.OWNERID = u.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER_ROLE` ur
        ON u.USERROLEID = ur.ID
    WHERE
        (
            STARTS_WITH(ur.NAME, 'RES Library')
            OR ur.NAME LIKE '%APAC China%'
            OR ur.NAME LIKE '%RES Customer Success%'
        )
        AND o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research')
        AND EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 10
    GROUP BY a.ID, a.ULTIMATE_PARENT_ACCOUNT_ID18__C
),
Ultimate_Parent_Summary AS (
    SELECT
        ULTIMATE_PARENT_ACCOUNT_ID18__C,
        MIN(First_Invoice_FY)               AS First_Invoice_FY_Parent
    FROM Opportunity_Summary
    GROUP BY ULTIMATE_PARENT_ACCOUNT_ID18__C
),
RankedCSQL AS (
    -- ✅ ROOT-CAUSE FIX for the ticks error:
    -- GAINSIGHT_CSQL.CREATED_DATE is a TIMESTAMP WITH TIME ZONE (e.g. ...-08:00 / -07:00).
    -- The Arrow connector reads it via DateTimeOffset(ticks, offset), and the offset
    -- arithmetic overflows the .NET DateTime ticks range -> "Ticks must be between..." error.
    -- Wrapping in DATE() strips the timezone offset so no DateTimeOffset is constructed.
    SELECT
        OPPORTUNITY_ID,
        TYPE_NAME                           AS CSQL_TYPE,
        POTENTIAL_REVENUE,
        OWNER_NAME,
        ROW_NUMBER() OVER (
            PARTITION BY OPPORTUNITY_ID
            ORDER BY DATE(CREATED_DATE) DESC   -- ✅ strip TZ offset (was: CREATED_DATE DESC)
        )                                   AS rn
    FROM `prd-wiley-data.EDW_RESEARCH.GAINSIGHT_CSQL`
),
-- AccountRel AS (
--     SELECT *
--     FROM (
--         SELECT
--             ar.RELATED_ACCOUNT__C,
--             ar.ACCOUNT__C,
--             con.NAME                        AS consortium,
--             ROW_NUMBER() OVER (
--                 PARTITION BY ar.RELATED_ACCOUNT__C
--                 ORDER BY ar.CREATEDDATE DESC
--             )                               AS rn
--         FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
--         LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
--             ON con.ID = ar.ACCOUNT__C
--         WHERE
--             ar.ISDELETED = FALSE
--             AND ar.TYPE__C = 'Consortium Member'
--     )
--     WHERE rn = 1
-- ),
-- ============================================================
-- Account Relationship logic
-- Retain relationship priority:
--   1 = Consortium
--   2 = Consortium Member
--
-- Where multiple AR records exist within the same priority,
-- select the latest-modified AR record.
-- ============================================================

AccountRel AS (
    SELECT
        ACCOUNT_ID,
        consortium
    FROM (
        -- Priority 1: Consortium
        SELECT
            ar.RELATED_ACCOUNT__C AS ACCOUNT_ID,
            acct.NAME AS consortium,
            1 AS priority,
            ar.LASTMODIFIEDDATE AS AR_LASTMODIFIEDDATE
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar

        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` acct
            ON acct.ID = ar.RELATED_ACCOUNT__C

        WHERE ar.ISDELETED = FALSE
          AND ar.TYPE__C = 'Consortium'

        UNION ALL

        -- Priority 2: Consortium Member
        SELECT
            ar.RELATED_ACCOUNT__C AS ACCOUNT_ID,
            con.NAME AS consortium,
            2 AS priority,
            ar.LASTMODIFIEDDATE AS AR_LASTMODIFIEDDATE
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar

        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
            ON con.ID = ar.ACCOUNT__C

        WHERE ar.ISDELETED = FALSE
          AND ar.TYPE__C = 'Consortium Member'
    )

    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ACCOUNT_ID
        ORDER BY
            priority,
            AR_LASTMODIFIEDDATE DESC
    ) = 1
),

OppFieldHistory AS (
    SELECT *
    FROM (
        SELECT
            OPPORTUNITYID,
            SAFE_CAST(CREATEDDATE AS DATE)  AS Created_Dt,
            -- ✅ CLAMP: OFH.OLDVALUE range was up to 3033 -> guard to 1990–2100
            CASE WHEN SAFE_CAST(OLDVALUE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-12-31'
                 THEN SAFE_CAST(OLDVALUE AS DATE) ELSE NULL END          AS OLDVALUE,
            -- ✅ CLAMP: OFH.NEWVALUE range was up to 2121 -> guard to 1990–2100
            CASE WHEN SAFE_CAST(NEWVALUE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-12-31'
                 THEN SAFE_CAST(NEWVALUE AS DATE) ELSE NULL END          AS NEWVALUE,
            ROW_NUMBER() OVER (
                PARTITION BY OPPORTUNITYID
                ORDER BY CREATEDDATE DESC
            )                               AS ROW_NUMBER
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_FIELD_HISTORY` ofh
        WHERE
            FIELD = 'CloseDate'
            AND ISDELETED = FALSE
            AND EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(ofh.CREATEDDATE AS DATE), INTERVAL 8 MONTH))
                >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 1
    )
    WHERE ROW_NUMBER = 1
),
OppFieldHistory_Stage AS (
    SELECT
        OpportunityId,
        OldValue                AS Original_Stage,
        Prev_CreatedDate        AS StageChangeDate_Before_Lost
    FROM (
        SELECT
            OpportunityId,
            OldValue,
            NewValue,
            SAFE_CAST(CreatedDate AS DATE) AS CreatedDate,
            LAG(SAFE_CAST(CreatedDate AS DATE)) OVER (
                PARTITION BY OpportunityId
                ORDER BY CreatedDate ASC
            ) AS Prev_CreatedDate,
            ROW_NUMBER() OVER (
                PARTITION BY OpportunityId
                ORDER BY CreatedDate DESC
            ) AS rn
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_FIELD_HISTORY`
        WHERE
            Field = 'StageName'
            AND IsDeleted = FALSE
            AND EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(CreatedDate AS DATE), INTERVAL 8 MONTH))
                >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 1
    )
    WHERE NewValue = 'Lost' AND rn = 1
),
RenewalEligible_Invoices AS (
    SELECT
        o.ACCOUNTID,
        EXTRACT(YEAR FROM DATE_ADD(
            SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE),
            INTERVAL 8 MONTH
        ))                                  AS FY,
        CASE
            WHEN p.NAME IN ('Digital - A+I')                                                THEN 'Indexing'
            WHEN p.NAME IN ('Digital - Document Delivery')                                  THEN 'Document Delivery'
            WHEN p.NAME IN ('Digital - Full text')                                          THEN 'Aggregator'
            WHEN p.NAME IN ('Digital - Other Commercial', 'Digital – Machine Reading License') THEN 'Digital – Others'
            WHEN p.NAME IN ('Text and Data Mining')                                         THEN 'TDM'
            WHEN p.NAME IN (
                'Obooks - Advanced eText Social Sciences Collection',
                'Obooks - Advanced eText Psychology Collection',
                'Obooks - Advanced eText Humanities Collection'
            )                                                                               THEN 'Advanced eText'
            WHEN de.ID IS NOT NULL
                AND (de.DEAL_STATUS__C NOT IN ('Cancelled') OR de.DEAL_STATUS__C IS NULL)
                AND (p.FAMILY NOT IN ('WRA') OR p.FAMILY = 'Publishing Service')            THEN 'TA'
            WHEN de.DEAL_STATUS__C = 'Cancelled'
                AND p.FAMILY = 'Publishing Service'                                         THEN 'Journal'
            ELSE p.FAMILY
        END                                 AS prod_grp
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_LINE_ITEM` oli
        ON o.ID = oli.OPPORTUNITYID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_PRODUCT2` p
        ON p.ID = oli.PRODUCT2ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_DEAL__C` de
        ON de.ID = o.DEAL__C
    WHERE
        o.STAGENAME = 'Invoiced'
        AND EXTRACT(YEAR FROM DATE_ADD(
            SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 10
),
TA_Invoice_Summary AS (
    SELECT
        ACCOUNTID,
        MIN(FY)                             AS First_Invoice_FY_TA,
        MAX(CASE
            WHEN FY = EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 1
            THEN 1 ELSE 0
        END)                                AS Has_PFY_Invoice
    FROM RenewalEligible_Invoices
    WHERE prod_grp IN ('Journal', 'Publishing Service', 'TA')
    GROUP BY ACCOUNTID
)
SELECT
    EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(Reporting_Closed_Dt AS DATE), INTERVAL 8 MONTH))
        - EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH))     AS flg_FY_ord,
    ACCOUNT_ID,
    ACCOUNT_NAME,
    Agencies,
    Agency_Account_IDs,
    Amount_o,
    AMOUNT,
    AR_Account,
    AR_Consortium,
    CURRENCYISOCODE,
    CAMPAIGNID,
    Camp_Name,
    CLOSEDT,
    CLOSEDT_FP,
    COUNTRY,
    Customer_Status_Account,
    Customer_Status_Ultimate_Parent,
    Custom_Account_Tag,
    CSQL_TYPE,
    POTENTIAL_REVENUE,
    Csql_Owner,
    DEAL,
    DEAL_STATUS,
    DISCOUNT,
    INDUSTRY_CLASSIFICATION__C,
    INSTITUTIONAL_SALES_TIER,
    FULL_TIME_EQUIVALENT,
    INVOICE_INDICATOR,
    LATE_JOURNAL_RENEWAL,
    OID,
    O_CI_ID,
    ORT,
    OTYPE,
    OWNER,
    ofh_DateOfChange,
    ofh_OLDVALUE,
    ofh_NEWVALUE,
    Original_Stage,
    StageChangeDate_Before_Lost,
    Parent_Product,
    INTER_ACCOUNT,
    Inter_Account_ID,
    Primary_Campaign_Source,
    PRODDATE,
    PROD_FAMILY,
    PROD_GRP,
    PROD_NAME,
    SUB_PROD_NAME,
    RECORD_TYPE__C,
    Related_Consortium,
    RENEWAL_BY_GSA,
    Reporting_Closed_Dt,
    RISK_VALUE,
    RENEWAL_RISK__C,
    RISK_REASON__C,
    RENEWAL_RISK_NOTES__C,
    SFDC_oType,
    Sales_Region,
    Segment,
    STAGE,
    STARTDT,
    TA_MODEL,
    Territory,
    TIER_1_CLASSIFICATION__C,
    TIER_2_CLASSIFICATION__C,
    USER_ROLE_NAME,
    User_ID,
    ULTIMATE_PARENT_ACCOUNT_NAME,
    ULTIMATE_PARENT_ACCOUNT_ID18,
    RG_type_1,
    RG_type_2,
    LOST_REASON__C,
    LOST_REASON_NOTES__C,
    LASTACTIVITYDATE,
    Email_Count,
    Call_Count,
    Task_Count,
    Total_ActivityCount,
    TASKSUBTYPE,
    Task_Type,
    Task_Types,
    Latest_Email_Date,
    Latest_Call_Date,
    Latest_Task_Date,
    PUSHCOUNT,
    X3RD_PARTY_AGENT,
    ORDER_NUMBER__C,
    YEAR__C,
    REDUCTION_REASON__C,
    -- OLI_Original_Currency_Amount,
    OLI_Original_Currency,
    -- USD_PRIORYEAR_AMT depends on FX rates (removed) -> NULL placeholder
    SUM(OLI_Original_Currency_Amount)                                      AS OLI_Original_Currency_Amount,
    SUM(USD_PRIORYEAR_AMT)                                                  AS USD_PRIORYEAR_AMT,
    SUM(USD_Amount_Wght)                                                    AS USD_AMOUNT_WGHT,
    SUM(USD_Amount_Wght_CR)                                                 AS USD_AMOUNT_WGHT_CR,
    SUM(USD_AMT)                                                            AS USD_AMT
FROM (
    SELECT
        a.ID                                                                AS Account_ID,
        a.NAME                                                              AS Account_Name,
        COALESCE(Opty.Agencies, '')                                         AS Agencies,
        COALESCE(Opty.Agency_Account_IDs, '')                               AS Agency_Account_IDs,
        CAST(o.AMOUNT_AT_TODAYS_FX_RATE_USD__C AS FLOAT64)                  AS Amount_o,
        CAST(o.AMOUNT AS FLOAT64)                                           AS AMOUNT,
        o.CURRENCYISOCODE,
        o.CAMPAIGNID,
        Marketing.NAME                                                      AS Camp_Name,
        SAFE_CAST(o.CLOSEDATE AS DATE)                                      AS CloseDt,
        CASE WHEN SAFE_CAST(o.CLOSEDATE AS DATE) BETWEEN DATE '1990-01-01' AND DATE '2100-04-30'
             THEN DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH) ELSE NULL
        END                                                                 AS CloseDt_FP,
        CASE
            WHEN o.ACCOUNT_PRIMARY_COUNTRY__C IS NULL
            THEN INITCAP(a.PRIMARY_COUNTRY__C)
            ELSE INITCAP(o.ACCOUNT_PRIMARY_COUNTRY__C)
        END                                                                 AS Country,
        de.NAME                                                             AS Deal,
        de.DEAL_STATUS__C                                                   AS DEAL_STATUS,
        CAST(oli.DISCOUNT AS FLOAT64)                                       AS DISCOUNT,
        a.INDUSTRY_CLASSIFICATION__C,
        a.INSTITUTIONAL_SALES_TIER__C                                       AS INSTITUTIONAL_SALES_TIER,
        oli.INVOICE_INDICATOR__C                                            AS INVOICE_INDICATOR,
        CASE
            WHEN o.YEAR__C IS NULL THEN FALSE
            WHEN EXTRACT(MONTH FROM o.CLOSEDATE) < 5 THEN
                CASE
                    WHEN o.TYPE = 'Renewal'
                    AND CAST(o.YEAR__C AS INT64) < EXTRACT(YEAR FROM o.CLOSEDATE)
                    AND CAST(o.CONTAINS_JOURNAL_PRODUCT_LS__C AS BOOL) = TRUE
                    THEN TRUE ELSE FALSE
                END
            ELSE
                CASE
                    WHEN o.TYPE = 'Renewal'
                    AND CAST(o.YEAR__C AS INT64) < EXTRACT(YEAR FROM o.CLOSEDATE) + 1
                    AND CAST(o.CONTAINS_JOURNAL_PRODUCT_LS__C AS BOOL) = TRUE
                    THEN TRUE ELSE FALSE
                END
        END                                                                 AS Late_Journal_Renewal,
        o.ID                                                                AS oid,
        Marketing.OPPORTUNITY__C                                            AS O_CI_ID,
        o.OPPORTUNITY_RECORDTYPE__C                                         AS ORT,
        o.TYPE                                                              AS SFDC_oType,
        u.NAME                                                              AS Owner,
        u.ID                                                                AS User_ID,
        SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE)           AS PRODDATE,
        p.FAMILY                                                            AS prod_family,
        CASE
            WHEN p.NAME IN ('Permissions - RightsLink','Permissions - Pharma Marketing')    THEN 'Pharma Permissions'
            WHEN p.NAME = 'Collective Licensing - Statutory License/Educational'            THEN 'RRO'
            WHEN p.NAME = 'Permissions - COA Licensing'                                     THEN 'COA'
            WHEN p.FAMILY = 'Standard'                                                      THEN 'Permissions'
            WHEN p.PRODUCT_CATEGORY__C = 'Reprints'                                         THEN 'Reprint'
            WHEN p.PRODUCT_CATEGORY__C = 'Digest Editions/Compendiums'                      THEN 'Digest Edition'
            WHEN p.NAME LIKE '%Supplements -%'                                              THEN 'Supplements'
            WHEN p.NAME LIKE '%Projects -%'                                                 THEN 'Projects'
            WHEN p.NAME IN ('License - Digital - Partner','License - Digital - Content Asset Licensing') THEN 'AS 3rd Party Licensing'
            WHEN p.NAME IN ('Digital - A+I')                                                THEN 'Indexing'
            WHEN p.NAME IN ('Digital - Document Delivery')                                  THEN 'Document Delivery'
            WHEN p.NAME IN ('Digital - Full text')                                          THEN 'Aggregator'
            WHEN p.NAME IN ('Digital - Other Commercial','Digital – Machine Reading License') THEN 'Digital - Others'
            WHEN p.NAME IN ('Text and Data Mining')                                         THEN 'TDM'
            WHEN p.NAME IN (
                'Obooks - Advanced eText Social Sciences Collection',
                'Obooks - Advanced eText Psychology Collection',
                'Obooks - Advanced eText Humanities Collection'
            )                                                                               THEN 'Advanced eText'
            WHEN de.ID IS NOT NULL
                AND (de.DEAL_STATUS__C NOT IN ('Cancelled') OR de.DEAL_STATUS__C IS NULL)
                AND (p.FAMILY NOT IN ('WRA') OR p.FAMILY IN ('Publishing Service'))         THEN 'TA'
            WHEN de.DEAL_STATUS__C IN ('Cancelled')
                AND p.FAMILY IN ('Publishing Service')                                      THEN 'Journal'
            ELSE p.FAMILY
        END                                                                 AS prod_grp,
        p.NAME                                                              AS prod_name,
        c.NAME                                                              AS Primary_Campaign_Source,
        p.NAME                                                              AS sub_prod_name,
        a.RECORD_TYPE__C,
        RC.NAME                                                             AS Related_Consortium,
        CAST(o.RENEWAL_BY_GSA__C AS BOOL)                                   AS RENEWAL_BY_GSA,
        CAST(ROUND(
            IF(o.AMOUNT = 0 OR o.AMOUNT IS NULL, 0, oli.TOTALPRICE / o.AMOUNT)
            * o.RISK_VALUE__C, 0) AS FLOAT64)                               AS Risk_Value,
        o.RENEWAL_RISK__C,
        o.RISK_REASON__C,
        o.RENEWAL_RISK_NOTES__C,
        CASE
            WHEN o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales')
            THEN SAFE_CAST(o.CLOSEDATE AS DATE)
            ELSE SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE)
        END                                                                 AS Reporting_Closed_Dt,
        o.SALES_REGION__C                                                   AS Sales_Region,
        a.LS_SEGMENT__C                                                     AS Segment,
        o.STAGENAME                                                         AS STAGE,
        SAFE_CAST(o.CREATEDDATE AS DATE)                                    AS StartDt,
        de.TA_MODEL__C                                                      AS TA_MODEL,
        a.LS_TERRITORY__C                                                   AS Territory,
        a.TIER_1_CLASSIFICATION__C,
        a.TIER_2_CLASSIFICATION__C,
        CAST(a.FULL_TIME_EQUIVALENT__C AS FLOAT64)                          AS FULL_TIME_EQUIVALENT,
        ur.NAME                                                             AS User_Role_Name,
        a.ULTIMATE_PARENT_ACCOUNT_NAME__C                                   AS ULTIMATE_PARENT_ACCOUNT_NAME,
        a.ULTIMATE_PARENT_ACCOUNT_ID18__C                                   AS ULTIMATE_PARENT_ACCOUNT_ID18,
        o.LOST_REASON__C,
        o.LOST_REASON_NOTES__C,
        SAFE_CAST(o.LASTACTIVITYDATE AS DATE)                               AS LASTACTIVITYDATE,
        o.PUSHCOUNT,
        o.X3RD_PARTY_AGENT__C                                               AS X3RD_PARTY_AGENT,
        oli.ORDER_NUMBER__C,
        CAST(o.YEAR__C AS INT64)                                             AS YEAR__C,
        o.REDUCTION_REASON__C,
        pp.NAME                                                             AS Parent_Product,
        INITCAP(SPLIT(rgi.TYPE, '/')[SAFE_OFFSET(0)])                       AS RG_type_1,
        INITCAP(SPLIT(rgi.TYPE, '/')[SAFE_OFFSET(1)])                       AS RG_type_2,
        ai.NAME                                                             AS Inter_Account,
        ai.ID                                                               AS Inter_Account_ID,
        ar.ACCOUNT_ID                                                       AS AR_Account,
        ar.consortium                                                       AS AR_Consortium,
        ofh.Created_Dt                                                      AS ofh_DateOfChange,
        ofh.OLDVALUE                                                        AS ofh_OLDVALUE,
        ofh.NEWVALUE                                                        AS ofh_NEWVALUE,
        ofhs.Original_Stage,
        ofhs.StageChangeDate_Before_Lost,
        csql.CSQL_TYPE,
        CAST(csql.POTENTIAL_REVENUE AS FLOAT64)                             AS POTENTIAL_REVENUE,
        csql.OWNER_NAME                                                     AS Csql_Owner,
        la.Email_Count,
        la.Call_Count,
        la.Task_Count,
        la.Total_ActivityCount,
        la.Latest_Task_Subtype                                              AS TASKSUBTYPE,
        la.Latest_Task_Type                                                 AS Task_Type,
        la.Task_Types,
        la.Latest_Email_Date,
        la.Latest_Call_Date,
        la.Latest_Task_Date,
        CASE
            WHEN (
                CASE
                    WHEN p.NAME IN ('Permissions - RightsLink','Permissions - Pharma Marketing')    THEN 'Pharma Permissions'
                    WHEN p.NAME = 'Collective Licensing - Statutory License/Educational'            THEN 'RRO'
                    WHEN p.NAME = 'Permissions - COA Licensing'                                     THEN 'COA'
                    WHEN p.FAMILY = 'Standard'                                                      THEN 'Permissions'
                    WHEN p.PRODUCT_CATEGORY__C = 'Reprints'                                         THEN 'Reprint'
                    WHEN p.PRODUCT_CATEGORY__C = 'Digest Editions/Compendiums'                      THEN 'Digest Edition'
                    WHEN p.NAME LIKE '%Supplements -%'                                              THEN 'Supplements'
                    WHEN p.NAME LIKE '%Projects -%'                                                 THEN 'Projects'
                    WHEN p.NAME IN ('License - Digital - Partner','License - Digital - Content Asset Licensing') THEN 'AS 3rd Party Licensing'
                    WHEN p.NAME IN ('Digital - A+I')                                                THEN 'Indexing'
                    WHEN p.NAME IN ('Digital - Document Delivery')                                  THEN 'Document Delivery'
                    WHEN p.NAME IN ('Digital - Full text')                                          THEN 'Aggregator'
                    WHEN p.NAME IN ('Digital - Other Commercial','Digital – Machine Reading License') THEN 'Digital - Others'
                    WHEN p.NAME IN ('Text and Data Mining')                                         THEN 'TDM'
                    WHEN p.NAME IN (
                        'Obooks - Advanced eText Social Sciences Collection',
                        'Obooks - Advanced eText Psychology Collection',
                        'Obooks - Advanced eText Humanities Collection'
                    )                                                                               THEN 'Advanced eText'
                    WHEN de.ID IS NOT NULL
                        AND (de.DEAL_STATUS__C NOT IN ('Cancelled') OR de.DEAL_STATUS__C IS NULL)
                        AND (p.FAMILY NOT IN ('WRA') OR p.FAMILY IN ('Publishing Service'))         THEN 'TA'
                    WHEN de.DEAL_STATUS__C IN ('Cancelled')
                        AND p.FAMILY IN ('Publishing Service')                                      THEN 'Journal'
                    ELSE p.FAMILY
                END
            ) = 'TA' THEN
                CASE
                    WHEN ta.First_Invoice_FY_TA IS NULL                                             THEN 'New'
                    WHEN EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
                        = ta.First_Invoice_FY_TA                                                    THEN 'New'
                    WHEN ta.Has_PFY_Invoice = 1                                                     THEN 'Renewal'
                    ELSE 'New'
                END
            ELSE o.TYPE
        END                                                                 AS OTYPE,
        CASE
            WHEN os.First_Invoice_FY IS NULL
                THEN 'New Customer'
            WHEN EXTRACT(
                    YEAR FROM DATE_ADD(
                        SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE),
                        INTERVAL 8 MONTH
                 )) <= os.First_Invoice_FY
                THEN 'New Customer'
            ELSE 'Existing Customer'
        END AS Customer_Status_Account,
        CASE
            WHEN ups.First_Invoice_FY_Parent IS NULL
                THEN 'New Customer'
            WHEN EXTRACT(
                    YEAR FROM DATE_ADD(
                        SAFE_CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE),
                        INTERVAL 8 MONTH
                 )) <= ups.First_Invoice_FY_Parent
                THEN 'New Customer'
            ELSE 'Existing Customer'
        END AS Customer_Status_Ultimate_Parent,
        CASE
            WHEN a.CUSTOM_TAGS__C LIKE ('%APAC LS Consortia Accounts%')     THEN 'APAC LS Consortia Accounts'
            WHEN a.CUSTOM_TAGS__C LIKE ('%EMEA LS Consortia Accounts%')     THEN 'EMEA LS Consortia Accounts'
            WHEN a.CUSTOM_TAGS__C LIKE ('%Americas LS Consortia Accounts%') THEN 'Americas LS Consortia Accounts'
            ELSE NULL
        END                                                                 AS Custom_Account_Tag,
        -- Product line-item value in original currency

        CAST(oli.TOTALPRICE AS FLOAT64) AS OLI_Original_Currency_Amount,
        oli.CURRENCYISOCODE AS OLI_Original_Currency,
        -- ✅ DIV0(a, b) → IF(b = 0 OR b IS NULL, 0, a / b)
--        CAST(ROUND(
--            IF(o.AMOUNT = 0 OR o.AMOUNT IS NULL, 0, oli.TOTALPRICE / o.AMOUNT)
--            * IF(COALESCE(fx.RATE, fx1.RATE) = 0 OR COALESCE(fx.RATE, fx1.RATE) IS NULL, 0,
--                o.PRIORYEARAMOUNT__C / COALESCE(fx.RATE, fx1.RATE)), 0)
--        AS FLOAT64)                                                         AS USD_PRIORYEAR_AMT,
        -- CAST(NULL AS FLOAT64) AS USD_PRIORYEAR_AMT,
        CAST(
            ROUND(
                IF(
                    o.AMOUNT = 0
                    OR o.AMOUNT IS NULL,
                    0,
                    (oli.TOTALPRICE / o.AMOUNT)
                    * COALESCE(o.PRIORYEARAMOUNT__C, 0)
                ),
                2
            ) AS FLOAT64
        ) AS USD_PRIORYEAR_AMT,

        CAST(
            COALESCE(oli.TOTAL_PRICE_AT_TODAY_S_FX_RATE_IN_USD__C, 0)
            * IF(o.PROBABILITY IS NULL, 0, o.PROBABILITY / 100)
        AS FLOAT64) AS USD_Amount_Wght,
        CAST(
            COALESCE(oli.TOTAL_PRICE_AT_TODAY_S_FX_RATE_IN_USD__C, 0)
            * IF(o.PROBABILITY IS NULL, 0, o.PROBABILITY / 100)
        AS FLOAT64) AS USD_Amount_Wght_CR,
        COALESCE(oli.TOTAL_PRICE_AT_TODAY_S_FX_RATE_IN_USD__C, 0) AS USD_AMT
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_LINE_ITEM` oli
        ON o.ID = oli.OPPORTUNITYID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_PRODUCT2` p
        ON p.ID = oli.PRODUCT2ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_PRODUCT2` pp
        ON oli.PARENT_PRODUCT__C = pp.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` a
        ON o.ACCOUNTID = a.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` ai
        ON o.INTERMEDIARY__C = ai.ID
    LEFT JOIN (
        SELECT CAST(RINGGOLD_ID AS STRING) AS RINGGOLD_ID, TYPE, PLACE_LONGITUDE, PLACE_LATITUDE
        FROM `prd-wiley-data.EDW_DS.RINGGOLD_INSTITUTIONS_MDM`
    ) rgi ON TRIM(a.RINGGOLD_ID__C) = TRIM(rgi.RINGGOLD_ID)
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` u
        ON o.OWNERID = u.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER_ROLE` ur
        ON u.USERROLEID = ur.ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_DEAL__C` de
        ON de.ID = o.DEAL__C
    LEFT JOIN Opportunity_Summary os
        ON os.ACCOUNTID = o.ACCOUNTID
    LEFT JOIN Ultimate_Parent_Summary ups
        ON ups.ULTIMATE_PARENT_ACCOUNT_ID18__C = a.ULTIMATE_PARENT_ACCOUNT_ID18__C
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` RC
        ON o.CLM_RELATED_CONSORTIUM__C = RC.ID
--    LEFT JOIN `prd-wiley-data.EDW_RESEARCH.SO_FX_PLANNED_RATES` fx
--        ON o.CURRENCYISOCODE = fx.FX
--        AND EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH)) = fx.FY
--    LEFT JOIN (
--        SELECT DISTINCT fx,
--            LAST_VALUE(rate) OVER (
--                PARTITION BY FX ORDER BY FY
--                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
--            ) AS RATE
--        FROM `prd-wiley-data.EDW_RESEARCH.SO_FX_PLANNED_RATES`
--    ) fx1 ON o.CURRENCYISOCODE = fx1.FX
    LEFT JOIN Opty
        ON o.ID = Opty.ID AND oli.ID = Opty.oliID
    LEFT JOIN Marketing
        ON o.ID = Marketing.OPPORTUNITY__C
    LEFT JOIN TaskCountsCTE la
        ON o.ID = la.Opportunity_ID
    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` c
        ON o.CAMPAIGNID = C.ID
    LEFT JOIN RankedCSQL csql
        ON o.ID = csql.OPPORTUNITY_ID AND csql.rn = 1
    LEFT JOIN AccountRel ar
        ON o.ACCOUNTID = ar.ACCOUNT_ID
    LEFT JOIN OppFieldHistory ofh
        ON o.ID = ofh.OPPORTUNITYID
    LEFT JOIN OppFieldHistory_Stage ofhs
        ON o.ID = ofhs.OpportunityId
    LEFT JOIN TA_Invoice_Summary ta
        ON ta.ACCOUNTID = o.ACCOUNTID
    WHERE
        (
            STARTS_WITH(ur.NAME, 'RES Library')
            OR ur.NAME LIKE '%APAC China%'
            OR ur.NAME LIKE '%RES Customer Success%'
            OR ur.NAME = 'RES Corporate Health Reprints Team'
            OR ur.NAME = 'RES Corporate R&D A&I Team'
            OR ur.NAME = 'RES Corporate R&D A&I Director'
            OR (
                u.NAME = 'Julie Attrill'
                AND ur.NAME = 'RES Library Translations'
            )
            OR (
            u.NAME = 'Rosemary Manning'
            AND ur.NAME = 'RES Corporate Sales Coordination'
            )
        )
        AND o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research', 'Corporate Sales')
        AND oli.ISDELETED = FALSE
        AND EXTRACT(YEAR FROM DATE_ADD(SAFE_CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
            >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
        -- ✅ JULIE EXCEPTION: normally exclude M3/Standard, but allow Julie
        -- Attrill's opps through — including Standard AND NULL product family
        -- (a NULL family would otherwise be dropped by NOT IN).
AND (
    p.FAMILY NOT IN ('M3', 'Standard')
    OR (
        ur.NAME IN (
            'RES Library Translations',
            'RES Library Digital Team'
        )
        AND (
            p.FAMILY = 'Standard' 
            OR p.FAMILY IS NULL
            )
    )
)
)
GROUP BY
    ACCOUNT_ID, ACCOUNT_NAME, Agencies, Agency_Account_IDs,
    Amount_o, AMOUNT, AR_Account, AR_Consortium, CURRENCYISOCODE,
    CAMPAIGNID, Camp_Name, CLOSEDT, CLOSEDT_FP, COUNTRY,
    Customer_Status_Account, Customer_Status_Ultimate_Parent,
    Custom_Account_Tag, CSQL_TYPE, POTENTIAL_REVENUE, Csql_Owner,
    DEAL, DEAL_STATUS, DISCOUNT, INDUSTRY_CLASSIFICATION__C,FULL_TIME_EQUIVALENT,
    INSTITUTIONAL_SALES_TIER, INVOICE_INDICATOR, LATE_JOURNAL_RENEWAL,
    OID, O_CI_ID, ORT, OTYPE, OWNER, ofh_DateOfChange,
    ofh_OLDVALUE, ofh_NEWVALUE, Original_Stage, StageChangeDate_Before_Lost,
    Parent_Product, INTER_ACCOUNT, Inter_Account_ID, Primary_Campaign_Source,
    PRODDATE, PROD_FAMILY, PROD_GRP, PROD_NAME, SUB_PROD_NAME,
    RECORD_TYPE__C, Related_Consortium, RENEWAL_BY_GSA, Reporting_Closed_Dt,
    RISK_VALUE, RENEWAL_RISK__C, RISK_REASON__C, RENEWAL_RISK_NOTES__C,
    SFDC_oType, Sales_Region, Segment, STAGE, STARTDT, TA_MODEL,
    Territory, TIER_1_CLASSIFICATION__C, TIER_2_CLASSIFICATION__C,
    USER_ROLE_NAME, User_ID, ULTIMATE_PARENT_ACCOUNT_NAME,
    ULTIMATE_PARENT_ACCOUNT_ID18, RG_type_1, RG_type_2,
    LOST_REASON__C, LOST_REASON_NOTES__C, LASTACTIVITYDATE,
    Email_Count, Call_Count, Task_Count, Total_ActivityCount,
    TASKSUBTYPE, Task_Type, Task_Types, Latest_Email_Date,
    Latest_Call_Date, Latest_Task_Date, PUSHCOUNT, X3RD_PARTY_AGENT,
    ORDER_NUMBER__C, YEAR__C, REDUCTION_REASON__C,
    OLI_Original_Currency
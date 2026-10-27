-- =============================================================================
-- IS Account Plans
-- Standalone Account Plan table
--
-- Grain:
--   One row per Account Plan ID
--
-- Eligibility:
--   Accounts must satisfy the same IS rules and filters used by IS Accounts.
--
-- Selection indicators:
--   AP_IsSelectedPlan identifies the plan that would previously have been
--   surfaced in Accounts:
--     1. Active plan first
--     2. Latest CreatedDate as tiebreaker
--
-- Date handling:
--   DATE() is applied to source timestamp/date columns to avoid TZ/ticks issues.
--
-- Objective activity (added):
--   AP_LatestObjectiveModifiedDate returns the most recent Objective-level
--   LastModifiedDate per Account Plan from the Account Plan Objective object.
--   Unlike the Account Plan LastModifiedDate (bulk/system updated), the
--   Objective LastModifiedDate is unique per record, so it can act as an
--   additional indicator of user-driven activity. Used for visibility only;
--   it does NOT change plan selection ranking.
-- =============================================================================

WITH

-- -----------------------------------------------------------------------------
-- Apply the same IS business rules and filters and return one row per account.
-- -----------------------------------------------------------------------------
EligibleISAccounts AS (
    SELECT DISTINCT
        a.ID AS ACCOUNT_ID

    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY` o

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_OPPORTUNITY_LINE_ITEM` oli
        ON o.ID = oli.OPPORTUNITYID

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_PRODUCT2` p
        ON p.ID = oli.PRODUCT2ID

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` a
        ON o.ACCOUNTID = a.ID

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` u
        ON o.OWNERID = u.ID

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER_ROLE` ur
        ON u.USERROLEID = ur.ID

    LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_DEAL__C` de
        ON de.ID = o.DEAL__C

    WHERE
        (
            STARTS_WITH(ur.NAME, 'RES Library')
            OR ur.NAME LIKE '%APAC China%'
            OR ur.NAME LIKE '%RES Customer Success%'
            OR ur.NAME = 'RES Corporate Health Reprints Team'
            OR ur.NAME = 'RES Corporate R&D A&I Team'
            OR ur.NAME = 'RES Corporate R&D A&I Director'
            OR (
                u.NAME = 'Emily Cammish'
                AND ur.NAME = 'K&L Emerging Models Translations Team'
            )
            OR (
                u.NAME = 'Julie Attrill'
                AND ur.NAME = 'RES Library Translations'
            )
        )

        AND o.OPPORTUNITY_RECORDTYPE__C IN (
            'Institutional Sales',
            'R&L Research',
            'Corporate Sales'
        )

        AND oli.ISDELETED = FALSE

        AND EXTRACT(
            YEAR FROM DATE_ADD(
                SAFE_CAST(o.CLOSEDATE AS DATE),
                INTERVAL 8 MONTH
            )
        ) >= EXTRACT(
            YEAR FROM DATE_ADD(
                CURRENT_DATE(),
                INTERVAL 8 MONTH
            )
        ) - 3

        AND (
            p.FAMILY NOT IN ('M3', 'Standard')
            OR (
                u.NAME = 'Julie Attrill'
                AND ur.NAME = 'RES Library Translations'
                AND (
                    p.FAMILY = 'Standard'
                    OR p.FAMILY IS NULL
                )
            )
        )

        AND o.ID IS NOT NULL
),

AM_Mapping AS (
    SELECT *
    FROM (
        SELECT DISTINCT
            lam.NAME AS GSP_AM,
            atm.ACCOUNTID,
            atm.TEAMMEMBERROLE,
            atm.USERID,
            atm.TITLE,
            DATE(atm.LASTMODIFIEDDATE) AS LASTMODIFIEDDATE,
            ROW_NUMBER() OVER (
                PARTITION BY atm.ACCOUNTID
                ORDER BY DATE(atm.LASTMODIFIEDDATE) DESC
            ) AS ROW_NUMBER
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
            ON lam.ID = atm.USERID
        WHERE atm.TEAMMEMBERROLE IN (
                'GSP Account Manager',
                'Global Account Manager'
            )
        AND atm.ISDELETED = FALSE
    )
    WHERE ROW_NUMBER = 1
),

SC_Mapping AS (
    SELECT *
    FROM (
        SELECT DISTINCT
            lam.NAME AS IS_Sales_Coordinator,
            atm.ACCOUNTID,
            atm.TEAMMEMBERROLE,
            atm.USERID,
            atm.TITLE,
            DATE(atm.LASTMODIFIEDDATE) AS LASTMODIFIEDDATE,
            ROW_NUMBER() OVER (
                PARTITION BY atm.ACCOUNTID
                ORDER BY DATE(atm.LASTMODIFIEDDATE) DESC
            ) AS ROW_NUMBER
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
            ON lam.ID = atm.USERID
        WHERE atm.TEAMMEMBERROLE = 'IS Sales Coordinator'
        AND atm.ISDELETED = FALSE
    )
    WHERE ROW_NUMBER = 1
),

CSM_Mapping AS (
    SELECT *
    FROM (
        SELECT DISTINCT
            lam.NAME AS Customer_Success_Manager,
            atm.ACCOUNTID,
            atm.TEAMMEMBERROLE,
            atm.USERID,
            atm.TITLE,
            DATE(atm.LASTMODIFIEDDATE) AS LASTMODIFIEDDATE,
            ROW_NUMBER() OVER (
                PARTITION BY atm.ACCOUNTID
                ORDER BY DATE(atm.LASTMODIFIEDDATE) DESC
            ) AS ROW_NUMBER
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
            ON lam.ID = atm.USERID
        WHERE atm.TEAMMEMBERROLE = 'Customer Success Manager'
        AND atm.ISDELETED = FALSE
    )
    WHERE ROW_NUMBER = 1
),

AccountRel AS (
    SELECT *
    FROM (
        SELECT
            ar.RELATED_ACCOUNT__C,
            ar.ACCOUNT__C,
            con.NAME AS consortium,
            ROW_NUMBER() OVER (
                PARTITION BY ar.RELATED_ACCOUNT__C
                ORDER BY DATE(ar.CREATEDDATE) DESC
            ) AS rn
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
            ON con.ID = ar.ACCOUNT__C
        WHERE ar.ISDELETED = FALSE
        AND ar.TYPE__C = 'Consortium Member'
    )
    WHERE rn = 1
),

-- -----------------------------------------------------------------------------
-- Retain every non-deleted Account Plan.
-- Add count and active-first sequence within each account.
-- -----------------------------------------------------------------------------
AccountPlans AS (
    SELECT
        ap.*,

        COUNT(*) OVER (
            PARTITION BY ap.ACCOUNTID
        ) AS AP_TOTAL_PLANS,

        ROW_NUMBER() OVER (
            PARTITION BY ap.ACCOUNTID
            ORDER BY
                CASE
                    WHEN ap.STATUS = 'Active' THEN 1
                    ELSE 2
                END,
                DATE(ap.CREATEDDATE) DESC,
                ap.ID DESC
        ) AS AP_PLAN_SEQUENCE

    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_PLAN` ap
    WHERE ap.ISDELETED = FALSE
),

-- -----------------------------------------------------------------------------
-- Latest Objective activity per Account Plan.
-- Objective LastModifiedDate is unique per record (not bulk-updated like the
-- Account Plan LastModifiedDate), so MAX() gives the most recent objective-level
-- change for each plan. Used as an additional activity indicator only and
-- aggregated to one row per ACCOUNTPLANID to avoid row multiplication.
-- -----------------------------------------------------------------------------
ObjectiveActivity AS (
    SELECT
        obj.ACCOUNTPLANID,
        MAX(DATE(obj.LASTMODIFIEDDATE)) AS AP_LatestObjectiveModifiedDate,
        COUNT(*)                        AS AP_ObjectiveCount
    FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_PLAN_OBJECTIVE` obj
    WHERE obj.ISDELETED = FALSE
    GROUP BY obj.ACCOUNTPLANID
)

SELECT
    -- Account Plan key and relationship
    ap.ID AS AP_PlanId,
    ap.ACCOUNTID AS ACCOUNT_ID,

    -- Account information
    -- a.NAME AS Account_Name,
    -- ar.consortium AS consortium,
    -- a.PRIMARY_COUNTRY__C,
    -- a.LS_SEGMENT__C AS Segment,
    -- a.LS_TERRITORY__C AS Territory,
    -- a.TIER_1_CLASSIFICATION__C,
    -- a.TIER_2_CLASSIFICATION__C,
    -- a.RECORD_TYPE__C,
    -- a.INDUSTRY_CLASSIFICATION__C,
    -- a.INSTITUTIONAL_SALES_TIER__C,
    -- a.WINTOUCH_ID__C,
    -- a.WINTOUCH_EUR_ID__C,
    -- a.ECID__C,
    -- a.CRM_LEGAL_NAME__C,

    -- Existing account ownership mappings
    am.GSP_AM,
    sc.IS_Sales_Coordinator,
    csm.Customer_Success_Manager,

    -- Account Plan identification
    ap.AP_TOTAL_PLANS AS AP_TotalPlans,
    ap.AP_PLAN_SEQUENCE AS AP_PlanSequence,

    CASE
        WHEN ap.AP_PLAN_SEQUENCE = 1 THEN TRUE
        ELSE FALSE
    END AS AP_IsSelectedPlan,

    ap.NAME AS AP_PlanName,
    ap.STATUS AS AP_Status,
    apu.NAME AS AP_Owner,

    -- Account Plan dates
    DATE(ap.STARTDATE) AS AP_StartDate,
    DATE(ap.ENDDATE) AS AP_EndDate,
    DATE(ap.CREATEDDATE) AS AP_CreatedDate,
    DATE(ap.LASTMODIFIEDDATE) AS AP_LastModifiedDate_Refresh,

    -- Objective-based activity indicators (added)
    oa.AP_LatestObjectiveModifiedDate AS AP_LatestObjectiveModifiedDate,
    oa.AP_ObjectiveCount              AS AP_ObjectiveCount,
    GREATEST(
        DATE(ap.CREATEDDATE),
        COALESCE(oa.AP_LatestObjectiveModifiedDate, DATE(ap.CREATEDDATE))
    ) AS AP_LatestActivityDate,

    -- Account Plan strategic details
    ap.ACCOUNTVISION AS AP_Vision,
    ap.ACCOUNTCHALLENGES AS AP_Challenges,
    ap.ACCOUNTINDUSTRYTRENDS AS AP_IndustryTrends,
    ap.ACCOUNTSTRATEGICPRIORITIES AS AP_StrategicPriorities,
    ap.ACCOUNTPRFMINDICATORS AS AP_PerformanceIndicators,

    -- Account Plan competitive analysis
    ap.ACCOUNTCOMPETITORS AS AP_Competitors,
    ap.ACCOUNTCOMPETITIVESTRENGTHS AS AP_CompetitiveStrengths,
    ap.ACCOUNTCMPTVWEAKNESSES AS AP_CompetitiveWeaknesses,

    -- Account Plan relationship SWOT
    ap.RELATIONSHIPSTRENGTHS AS AP_RelationshipStrengths,
    ap.RELATIONSHIPWEAKNESSES AS AP_RelationshipWeaknesses,
    ap.RELATIONSHIPOPPORTUNITIES AS AP_RelationshipOpportunities,
    ap.RELATIONSHIPTHREATS AS AP_RelationshipThreats,

    -- Account Plan pipeline and financial measures
    ap.PIPELINE_STRENGTH__C AS AP_PipelineStrength,
    ap.WIN_RATE_BY_AMOUNT__C AS AP_WinRateByAmount,
    ap.OPEN_OPPORTUNITY_AMOUNT__C AS AP_OpenOpportunityAmount,
    ap.WON_OPPORTUNITY_AMOUNT__C AS AP_WonOpportunityAmount,
    ap.LOST_OPPORTUNITY_AMOUNT__C AS AP_LostOpportunityAmount,
    ap.INVOICED_OPPORTUNITY_AMOUNT__C AS AP_InvoicedOpportunityAmount,
    ap.IWP_TOTAL__C AS AP_IWPTotal,
    ap.IWP_WEIGHTED__C AS AP_IWPWeighted,

    -- Additional source information
    ap.CURRENCYISOCODE AS AP_CurrencyIsoCode,
    ap.NOTES AS AP_Notes

FROM AccountPlans ap

INNER JOIN EligibleISAccounts eis
    ON ap.ACCOUNTID = eis.ACCOUNT_ID

INNER JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` a
    ON ap.ACCOUNTID = a.ID

LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` apu
    ON ap.OWNERID = apu.ID

LEFT JOIN AccountRel ar
    ON ap.ACCOUNTID = ar.RELATED_ACCOUNT__C

LEFT JOIN AM_Mapping am
    ON ap.ACCOUNTID = am.ACCOUNTID

LEFT JOIN SC_Mapping sc
    ON ap.ACCOUNTID = sc.ACCOUNTID

LEFT JOIN CSM_Mapping csm
    ON ap.ACCOUNTID = csm.ACCOUNTID

LEFT JOIN ObjectiveActivity oa
    ON ap.ID = oa.ACCOUNTPLANID
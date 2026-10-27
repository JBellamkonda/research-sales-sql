-- =============================================================================
-- IS Accounts
-- Account Plan fields removed and moved to standalone Account Plans dataset
-- Existing IS rules and filters retained
-- =============================================================================

WITH

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

-- AccountRel AS (
--     SELECT *
--     FROM (
--         SELECT
--             ar.RELATED_ACCOUNT__C,
--             ar.ACCOUNT__C,
--             con.NAME AS consortium,
--             ROW_NUMBER() OVER (
--                 PARTITION BY ar.RELATED_ACCOUNT__C
--                 ORDER BY DATE(ar.CREATEDDATE) DESC
--             ) AS rn
--         FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
--         LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
--             ON con.ID = ar.ACCOUNT__C
--         WHERE ar.ISDELETED = FALSE
--           AND ar.TYPE__C = 'Consortium Member'
--     )
--     WHERE rn = 1
-- )

-- AccountRel AS (

--     -- Priority 1
--     -- If the account itself is a consortium,
--     -- use the consortium account name

--     SELECT
--         ACCOUNT_ID,
--         consortium
--     FROM (

--         SELECT
--             ar.RELATED_ACCOUNT__C AS ACCOUNT_ID,
--             acct.NAME AS consortium,
--             1 AS priority
--         FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
--         LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` acct
--             ON acct.ID = ar.RELATED_ACCOUNT__C
--         WHERE ar.ISDELETED = FALSE
--           AND ar.TYPE__C = 'Consortium'

--         UNION ALL

--         -- Priority 2
--         -- Member accounts inherit consortium name
--         -- from ACCOUNT__C

--         SELECT
--             ar.RELATED_ACCOUNT__C AS ACCOUNT_ID,
--             con.NAME AS consortium,
--             2 AS priority
--         FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
--         LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
--             ON con.ID = ar.ACCOUNT__C
--         WHERE ar.ISDELETED = FALSE
--           AND ar.TYPE__C = 'Consortium Member'

--     )

--     QUALIFY ROW_NUMBER() OVER (
--         PARTITION BY ACCOUNT_ID
--         ORDER BY priority
--     ) = 1

-- )

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
)

SELECT DISTINCT
    a.ID AS ACCOUNT_ID,
    ar.consortium AS consortium,
    a.NAME AS Account_Name,
    a.PRIMARY_COUNTRY__C,
    a.LS_SEGMENT__C AS Segment,
    a.LS_TERRITORY__C AS Territory,
    a.TIER_1_CLASSIFICATION__C,
    a.TIER_2_CLASSIFICATION__C,
    a.RECORD_TYPE__C,
    a.INDUSTRY_CLASSIFICATION__C,
    a.INSTITUTIONAL_SALES_TIER__C,
    a.WINTOUCH_ID__C,
    a.WINTOUCH_EUR_ID__C,
    a.ECID__C,
    a.CRM_LEGAL_NAME__C,
    am.GSP_AM,
    sc.IS_Sales_Coordinator,
    csm.Customer_Success_Manager

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

LEFT JOIN AccountRel ar
    ON o.ACCOUNTID = ar.ACCOUNT_ID

LEFT JOIN AM_Mapping am
    ON o.ACCOUNTID = am.ACCOUNTID

LEFT JOIN SC_Mapping sc
    ON o.ACCOUNTID = sc.ACCOUNTID

LEFT JOIN CSM_Mapping csm
    ON o.ACCOUNTID = csm.ACCOUNTID

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
        OR (
            u.NAME = 'Rosemary Manning'
            AND ur.NAME = 'RES Corporate Sales Coordination'
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

    AND o.ID IS NOT NULL
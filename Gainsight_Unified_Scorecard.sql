WITH
AM_Mapping AS (
    SELECT ACCOUNTID, AM
    FROM (
        SELECT
            lam.NAME    AS AM,
            atm.ACCOUNTID,
            ROW_NUMBER() OVER (
                PARTITION BY atm.ACCOUNTID
                ORDER BY atm.LASTMODIFIEDDATE DESC
            ) AS rn
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
            ON lam.ID = atm.USERID
        WHERE
            atm.TEAMMEMBERROLE IN ('Library Account Manager', 'IS Account Manager')
            AND atm.ISDELETED = FALSE
    ) sub
    WHERE rn = 1
),

SAM_Mapping AS (
    SELECT ACCOUNTID, SAM
    FROM (
        SELECT
            sam.NAME    AS SAM,
            atm.ACCOUNTID,
            ROW_NUMBER() OVER (
                PARTITION BY atm.ACCOUNTID
                ORDER BY atm.LASTMODIFIEDDATE DESC
            ) AS rn
        FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
        LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` sam
            ON sam.ID = atm.USERID
        WHERE
            atm.TEAMMEMBERROLE IN ('Library Strategic Account Manager')
            AND atm.ISDELETED = FALSE
    ) sub
    WHERE rn = 1
)

SELECT
    g.SFDC_ACCOUNT_ID,
    g.COMPANY_NAME,
    g.CSM_NAME,
--  COMPANY_ID,
    g.SCORECARD_NAME,
    g.MEASURE_NAME,
    -- ✅ STRING column → SAFE_CAST + SUBSTR + NULLIF
    SAFE_CAST(SUBSTR(NULLIF(g.MEASURE_MODIFIED_DATE, ''), 1, 10) AS DATE)   AS MEASURE_MODIFIED_DATE,
    g.CURRENT_SCORE_LABEL,
    g.ACTIVE_MEASURE,
    g.CURRENT_SCORE,
    g.PREVIOUS_SCORE,
    g.LABEL,
    g.LS_SEGMENT_LABEL,
--  CAST(g.UPDATED AS DATE) AS UPDATED_DATE,  -- TIMESTAMP column (commented out as in original)
    am.AM   AS AM_Name,
    sam.SAM AS SAM_Name
--  SOURCE

FROM `prd-wiley-data.EDW_RESEARCH.GAINSIGHT_UNIFIEDSCORECARD` g

LEFT JOIN AM_Mapping am
    ON g.SFDC_ACCOUNT_ID = am.ACCOUNTID

LEFT JOIN SAM_Mapping sam
    ON g.SFDC_ACCOUNT_ID = sam.ACCOUNTID

WHERE
    -- ✅ STRING column → SAFE_CAST + SUBSTR + NULLIF + dynamic fiscal year filter
    SAFE_CAST(SUBSTR(NULLIF(g.MEASURE_MODIFIED_DATE, ''), 1, 10) AS DATE)
        >= DATE_SUB(DATE_TRUNC(DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH), YEAR), INTERVAL 2 YEAR)
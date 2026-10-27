SELECT AM, ACCOUNTID, TEAMMEMBERROLE, USERID, TITLE, LASTMODIFIEDDATE
FROM (
    SELECT
        f.*,
        ROW_NUMBER() OVER (
            PARTITION BY ACCOUNTID
            ORDER BY
                CASE
                    -- ✅ Special case: ONLY Derek/Marielle — if they are the latest, take the SAM
                    WHEN Latest_Name IN ('Marielle Bryant')
                         AND TEAMMEMBERROLE IN ('Library Strategic Account Manager','IS Strategic Account Manager')
                        THEN 1
                    -- ✅ Everyone else: AM beats generic SAM
                    WHEN TEAMMEMBERROLE IN ('Library Account Manager','IS Account Manager')
                        THEN 2
                    -- Generic SAMs (and anything else) rank below AMs
                    ELSE 3
                END,
                LASTMODIFIEDDATE DESC   -- within band: most recent wins
        ) AS ROW_NUMBER
    FROM (
        SELECT
            b.*,
            FIRST_VALUE(AM) OVER (
                PARTITION BY ACCOUNTID
                ORDER BY LASTMODIFIEDDATE DESC
            ) AS Latest_Name          -- most-recently-modified member on the account
        FROM (
            SELECT
                LAM.NAME AS AM,
                atm.ACCOUNTID,
                atm.TEAMMEMBERROLE,
                atm.USERID,
                atm.TITLE,
                DATE(atm.LASTMODIFIEDDATE) AS LASTMODIFIEDDATE   -- ✅ strip TZ offset (fixes ticks error)
            FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
            LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
                ON lam.ID = atm.USERID
            WHERE atm.TEAMMEMBERROLE IN (
                    'Library Account Manager',
                    'IS Account Manager',
                    'Library Strategic Account Manager',
                    'IS Strategic Account Manager')
              AND atm.ISDELETED = FALSE
--              AND atm.ACCOUNTID='001d000001nWRSBAA4'
        ) b
    ) f
)
WHERE ROW_NUMBER = 1
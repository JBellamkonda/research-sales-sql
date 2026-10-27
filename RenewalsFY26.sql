/* PFY vs PFY-1 (flg_FY_ord -1 vs -2). Related: Renewals_CFY_PFY.sql (0 vs -1), Renewals_PFY1_PFY2.sql (-2 vs -3). */
WITH
-- 1) Reusable product grouping & FY calc for invoiced opps
RenewalEligible_Invoices AS (
 SELECT
 o.ACCOUNTID,
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
 END                                                     AS prod_grp,
 -- ✅ FY: TIMESTAMP → CAST to DATE before DATE_ADD
 EXTRACT(YEAR FROM DATE_ADD(
   CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH
 ))                                                      AS FY
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
     CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH))
     >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 10
),
-- 2) Account-level first invoice FY + prior flag
--    ✅ Has_PFY_Invoice checks FY = current_FY - 2
TA_Invoice_Summary AS (
 SELECT
   ACCOUNTID,
   MIN(FY)                                                 AS First_Invoice_FY_TA,
   MAX(CASE
     WHEN FY = EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 2
     THEN 1 ELSE 0
   END)                                                    AS Has_PFY_Invoice
 FROM RenewalEligible_Invoices
 WHERE prod_grp IN ('Journal', 'Publishing Service', 'TA')
 GROUP BY ACCOUNTID
),
AccountRel AS (
 SELECT RELATED_ACCOUNT__C, NAME AS consortium
 FROM (
   SELECT
     ar.RELATED_ACCOUNT__C,
     con.NAME,
     ROW_NUMBER() OVER (
       PARTITION BY ar.RELATED_ACCOUNT__C
       ORDER BY ar.CREATEDDATE DESC
     ) AS rn
   FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_REL` ar
   LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT` con
     ON con.ID = ar.ACCOUNT__C
   WHERE ar.ISDELETED = FALSE
     AND ar.TYPE__C = 'Consortium Member'
 ) sub
 WHERE rn = 1
),
AM_Mapping AS (
 SELECT ACCOUNTID, AM
 FROM (
   SELECT
     lam.NAME                                            AS AM,
     atm.ACCOUNTID,
     ROW_NUMBER() OVER (
       PARTITION BY atm.ACCOUNTID
       ORDER BY atm.LASTMODIFIEDDATE DESC
     ) AS rn
   FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_ACCOUNT_TEAM_MEMBER` atm
   LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` lam
     ON lam.ID = atm.USERID
   WHERE atm.TEAMMEMBERROLE IN ('Library Account Manager', 'IS Account Manager')
     AND atm.ISDELETED = FALSE
 ) sub
 WHERE rn = 1
),
Agreement_Deduped AS (
 SELECT
   ID,
   Apttus__Account__c                                      AS Agreement_AccountID,
   Apttus__Related_Opportunity__c                          AS Agreement_OpportunityID,
   Apttus__Contract_End_Date__c                            AS Agreement_End_Date
 FROM (
   SELECT
     ag.*,
     ROW_NUMBER() OVER (
       PARTITION BY COALESCE(ag.Apttus__Related_Opportunity__c, ag.Apttus__Account__c)
       -- ✅ NULLS LAST supported in BigQuery
       ORDER BY ag.Apttus__Contract_End_Date__c DESC NULLS LAST
     ) AS rn
   FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_AGREEMENT` ag
   WHERE ag.ISDELETED = FALSE
     -- ✅ TIMESTAMP → CAST to DATE before DATE_ADD
     AND EXTRACT(YEAR FROM DATE_ADD(
       CAST(ag.Apttus__Contract_End_Date__c AS DATE), INTERVAL 8 MONTH))
       >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH))
 ) sub
 WHERE rn = 1
),
MainQuery AS (
 SELECT
   a.ID                                                    AS ACCOUNTID,
   ar.consortium,
   a.NAME                                                  AS Account_Name,
   am.AM                                                   AS AM_Name,
   o.ID                                                    AS OpportunityID,
   o.StageName                                             AS STAGE,
   -- ✅ DIV0 → IF(b=0 OR b IS NULL, 0, a/b)
   CAST(ROUND(
     IF(o.AMOUNT = 0 OR o.AMOUNT IS NULL, 0, oli.TOTALPRICE / o.AMOUNT)
     * o.RISK_VALUE__C, 0) AS FLOAT64)                   AS Risk_Value,
   o.RENEWAL_RISK_NOTES__C,
   o.RENEWAL_RISK__C,
   o.RISK_REASON__C,
   p.NAME                                                  AS Product_Name,
   p.FAMILY                                                AS Product_Family,
   -- prod_grp
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
   END                                                     AS prod_grp,
   -- ✅ FIX: prod_grp alias inlined in oType CASE (BigQuery alias rule)
   CASE
     WHEN (
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
       END
     ) IN ('Journal', 'Publishing Service', 'TA') THEN
       CASE
         WHEN ta.First_Invoice_FY_TA IS NULL                                             THEN 'New'
         WHEN EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
           = ta.First_Invoice_FY_TA                                                    THEN 'New'
         WHEN ta.Has_PFY_Invoice = 1                                                     THEN 'Renewal'
         ELSE 'New'
       END
     ELSE 'New'
   END                                                     AS oType,
   o.TYPE                                                  AS SFDC_oType,
   -- ✅ NEW: Opportunity Year for USD_PFY/USD_CFY calculation
   CAST(o.YEAR__C AS INT64)                                AS YEAR__C,
   -- ✅ flg_FY_ord: full expression (alias cannot be used in same SELECT)
   EXTRACT(YEAR FROM DATE_ADD(
     CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH))
     - EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) AS flg_FY_ord,
   -- ✅ DIV0 → IF(b=0 OR b IS NULL, 0, a/b)
   CAST(ROUND(
     IF(COALESCE(fx.RATE, fx1.RATE) = 0 OR COALESCE(fx.RATE, fx1.RATE) IS NULL, 0,
       oli.TOTALPRICE / COALESCE(fx.RATE, fx1.RATE)), 2)
     AS FLOAT64)                                             AS USD_AMT,
   CAST(ROUND(
     IF(o.AMOUNT = 0 OR o.AMOUNT IS NULL, 0, oli.TOTALPRICE / o.AMOUNT)
     * IF(COALESCE(fx.RATE, fx1.RATE) = 0 OR COALESCE(fx.RATE, fx1.RATE) IS NULL, 0,
       o.PRIORYEARAMOUNT__C / COALESCE(fx.RATE, fx1.RATE)), 2)
     AS FLOAT64)                                             AS USD_PFY_FROM_CFY_OPP,
   -- ✅ FIX: Snowflake boolean expressions → explicit CASE WHEN in BigQuery
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
   END                                                     AS Late_Journal_Renewal,
   -- ✅ FIX: o.OPPORTUNITY_RECORDTYPE__C used directly (no alias reference)
   CASE
     WHEN o.OPPORTUNITY_RECORDTYPE__C = 'Institutional Sales'
     THEN CAST(o.CLOSEDATE AS DATE)
     ELSE CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE)
   END                                                     AS Reporting_Closed_Dt,
   CAST(ad.Agreement_End_Date AS DATE)                     AS Agreement_End_Date
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
 LEFT JOIN `prd-wiley-data.EDW_RESEARCH.SO_FX_PLANNED_RATES` fx
   ON o.CURRENCYISOCODE = fx.FX
  --  AND EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH)) = fx.FY
  AND fx.FY =
      EXTRACT(
          YEAR FROM DATE_ADD(
              CURRENT_DATE(),
              INTERVAL 8 MONTH
          )
      ) - 1
      
 LEFT JOIN (
   SELECT DISTINCT FX,
     -- ✅ LAST_VALUE needs explicit window frame in BigQuery
     LAST_VALUE(RATE) OVER (
       PARTITION BY FX ORDER BY FY
       ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
     ) AS RATE
   FROM `prd-wiley-data.EDW_RESEARCH.SO_FX_PLANNED_RATES`
 ) fx1 ON o.CURRENCYISOCODE = fx1.FX
 LEFT JOIN TA_Invoice_Summary ta
   ON ta.ACCOUNTID = o.ACCOUNTID
 LEFT JOIN AccountRel ar
   ON o.ACCOUNTID = ar.RELATED_ACCOUNT__C
 LEFT JOIN AM_Mapping am
   ON a.ID = am.ACCOUNTID
 LEFT JOIN Agreement_Deduped ad
   ON o.ID = ad.Agreement_OpportunityID
   OR o.ACCOUNTID = ad.Agreement_AccountID
 WHERE
   (
     STARTS_WITH(ur.NAME, 'RES Library')
     OR ur.NAME LIKE '%APAC China%'
     OR ur.NAME LIKE '%RES Customer Success%'
     OR ur.NAME = 'RES Corporate Health Reprints Team'
     OR ur.NAME = 'RES Corporate R&D A&I Team'
     OR ur.NAME = 'RES Corporate R&D A&I Director'
   )
   AND o.OPPORTUNITY_RECORDTYPE__C IN ('Institutional Sales', 'R&L Research')
   AND oli.ISDELETED = FALSE
   AND EXTRACT(YEAR FROM DATE_ADD(CAST(o.CLOSEDATE AS DATE), INTERVAL 8 MONTH))
     >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
   -- ✅ Additional YEAR__C filter (NULL-safe)
   AND (
     CAST(o.YEAR__C AS INT64)
       >= EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 3
     OR o.YEAR__C IS NULL
   )
   AND p.FAMILY NOT IN ('M3', 'Standard')
   -- ✅ flg_FY_ord = -1 allows all stages; others must be Invoiced
   AND (
     (
       EXTRACT(YEAR FROM DATE_ADD(
         CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH))
         - EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) = -1
     )
     OR (
       EXTRACT(YEAR FROM DATE_ADD(
         CAST(COALESCE(oli.SERVICEDATE, o.CLOSEDATE) AS DATE), INTERVAL 8 MONTH))
         - EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) <> -1
       AND o.StageName = 'Invoiced'
     )
   )
),
AggDates AS (
 SELECT
   ACCOUNTID,
   prod_grp,
   Product_Name,
   MAX(CASE WHEN flg_FY_ord = -1 THEN Reporting_Closed_Dt END) AS CloseDate_PFY,
   MAX(CASE WHEN flg_FY_ord = -2 THEN Reporting_Closed_Dt END) AS CloseDate_PFY_1,
   MAX(CASE WHEN flg_FY_ord = -3 THEN Reporting_Closed_Dt END) AS CloseDate_PFY_2,
   MAX(CASE WHEN flg_FY_ord = -4 THEN Reporting_Closed_Dt END) AS CloseDate_PFY_3
 FROM MainQuery
 GROUP BY ACCOUNTID, prod_grp, Product_Name
),
Has_Closed_PFY_Opps AS (
 SELECT DISTINCT ACCOUNTID
 FROM MainQuery
 WHERE flg_FY_ord = -1
   AND STAGE IN ('Invoiced', 'Won', 'Lost')
   AND prod_grp IN ('Journal', 'Publishing Service', 'TA')
),
Has_Opened_PFY_Opps AS (
 SELECT DISTINCT ACCOUNTID
 FROM MainQuery
 WHERE flg_FY_ord = -1
   AND STAGE NOT IN ('Invoiced', 'Won', 'Lost')
   AND prod_grp IN ('Journal', 'Publishing Service', 'TA')
),
FinalAgg AS (
 SELECT
   mq.consortium,
   mq.ACCOUNTID,
   mq.Account_Name,
   mq.AM_Name,
   mq.OpportunityID,
   mq.flg_FY_ord,
   mq.oType,
   mq.YEAR__C,
   SUM(CASE WHEN mq.flg_FY_ord = -1 THEN mq.Risk_Value ELSE 0 END) AS Risk_Value,
   STRING_AGG(DISTINCT CASE WHEN mq.flg_FY_ord = -1 THEN mq.RENEWAL_RISK__C END,
     '; ' ORDER BY CASE WHEN mq.flg_FY_ord = -1 THEN mq.RENEWAL_RISK__C END)     AS Renewal_Risk,
   STRING_AGG(DISTINCT CASE WHEN mq.flg_FY_ord = -1 THEN mq.RENEWAL_RISK_NOTES__C END,
     '; ' ORDER BY CASE WHEN mq.flg_FY_ord = -1 THEN mq.RENEWAL_RISK_NOTES__C END) AS Renewal_Risk_Notes,
   STRING_AGG(DISTINCT CASE WHEN mq.flg_FY_ord = -1 THEN mq.RISK_REASON__C END,
     '; ' ORDER BY CASE WHEN mq.flg_FY_ord = -1 THEN mq.RISK_REASON__C END)      AS Renewal_Risk_Reason,
   mq.STAGE,
   mq.Product_Name,
   mq.Product_Family,
   mq.prod_grp,
   mq.Late_Journal_Renewal,
   -- ✅ USD_PFY_1: YEAR__C + flg_FY_ord + Stage-aware split
   -- (YEAR2025 & FY2025) + (YEAR2024 & FY2025) + (YEAR2025 & FY2026 & Invoiced only)
   SUM(CASE
     WHEN mq.flg_FY_ord = -2
     OR (mq.YEAR__C = EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 2
         AND mq.flg_FY_ord = -1
         AND mq.STAGE = 'Invoiced')
     THEN mq.USD_AMT ELSE 0
   END)                                                                            AS USD_PFY_1,
   SUM(CASE WHEN mq.flg_FY_ord = -1 THEN mq.USD_PFY_FROM_CFY_OPP ELSE 0 END)    AS USD_PFY1_FROM_PFY_OPP,
   -- ✅ USD_PFY: YEAR__C + flg_FY_ord + Stage-aware split
   -- (YEAR2026 & FY2026) + (YEAR2025 & FY2026 & NOT Invoiced — open pipeline)
   SUM(CASE
     WHEN (mq.YEAR__C = EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 1
       AND mq.flg_FY_ord = -1)
     OR (mq.YEAR__C = EXTRACT(YEAR FROM DATE_ADD(CURRENT_DATE(), INTERVAL 8 MONTH)) - 2
         AND mq.flg_FY_ord = -1
         AND mq.STAGE NOT IN ('Invoiced'))
     THEN mq.USD_AMT ELSE 0
   END)                                                                            AS USD_PFY,
   ad.CloseDate_PFY,
   ad.CloseDate_PFY_1,
   ad.CloseDate_PFY_2,
   ad.CloseDate_PFY_3,
   MAX(mq.Agreement_End_Date)                                                      AS Agreement_End_Date,
   CASE WHEN hco.ACCOUNTID IS NOT NULL THEN TRUE ELSE FALSE END                    AS Has_Closed_PFY_Opps,
   CASE WHEN ho.ACCOUNTID  IS NOT NULL THEN TRUE ELSE FALSE END                    AS Has_Opened_PFY_Opps
 FROM MainQuery mq
 LEFT JOIN AggDates ad
   ON mq.ACCOUNTID = ad.ACCOUNTID
   AND mq.prod_grp = ad.prod_grp
   AND mq.Product_Name = ad.Product_Name
 LEFT JOIN Has_Closed_PFY_Opps hco ON mq.ACCOUNTID = hco.ACCOUNTID
 LEFT JOIN Has_Opened_PFY_Opps ho  ON mq.ACCOUNTID = ho.ACCOUNTID
 WHERE mq.prod_grp IN ('Journal', 'Publishing Service', 'TA')
 GROUP BY
   mq.consortium, mq.Account_Name, mq.AM_Name, mq.OpportunityID,
   mq.STAGE, mq.prod_grp, mq.Product_Family, mq.Late_Journal_Renewal,
   ad.CloseDate_PFY, ad.CloseDate_PFY_1, ad.CloseDate_PFY_2, ad.CloseDate_PFY_3,
   hco.ACCOUNTID, ho.ACCOUNTID, mq.flg_FY_ord, mq.Product_Name,
   mq.ACCOUNTID, mq.oType, mq.YEAR__C
 HAVING
   COALESCE(SUM(CASE WHEN mq.flg_FY_ord = -2 THEN mq.USD_AMT ELSE 0 END), 0) <> 0
   OR COALESCE(SUM(CASE WHEN mq.flg_FY_ord = -1 THEN mq.USD_AMT ELSE 0 END), 0) <> 0
   OR MAX(mq.Late_Journal_Renewal) = TRUE
)
SELECT
 *,
 ROUND(USD_PFY - USD_PFY1_FROM_PFY_OPP, 2)                   AS USD_PFY_vs_PFY1_FROM_PFY_DIFF,
 ROUND(IF(NULLIF(USD_PFY1_FROM_PFY_OPP, 0) IS NULL, 0,
   (USD_PFY - USD_PFY1_FROM_PFY_OPP) / NULLIF(USD_PFY1_FROM_PFY_OPP, 0)) * 100, 2) AS USD_PFY_vs_PFY1_FROM_PFY_PCT,
 ROUND(USD_PFY - USD_PFY_1, 2)                                 AS USD_PFY_vs_PFY1_DIFF,
 ROUND(IF(NULLIF(USD_PFY_1, 0) IS NULL, 0,
   (USD_PFY - USD_PFY_1) / NULLIF(USD_PFY_1, 0)) * 100, 2)    AS USD_PFY_vs_PFY1_PCT,
 CASE
   WHEN ROUND(USD_PFY_1, 2) = ROUND(USD_PFY1_FROM_PFY_OPP, 2)
   THEN 'MATCH' ELSE 'MISMATCH'
 END                                                         AS PRIOR_AMT_MATCH_FLAG
FROM FinalAgg
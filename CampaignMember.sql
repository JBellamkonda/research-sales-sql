SELECT DISTINCT
    cm.CAMPAIGN_MEMBER_ID18__C,
    c.NAME                                          AS Campaign_Name,
    cm.CAMPAIGNID,
    cm.TYPE,
    -- ✅ TIMESTAMP → CAST to DATE
    CAST(cm.CREATEDDATE AS DATE)                    AS CREATEDDATE,
    cm.COMMENTS__C,
    cm.UNQUALIFIED_REASON__C,
    cm.NAME                                         AS CamPaign_Member_Name,
    cm.EMAIL                                        AS CamPaign_Member_Email,
    cm.COMPANYORACCOUNT                             AS Company,
    cm.CAMPAIGN_MEMBER_TO_OPPORTUNITY_STATUS__C,
    cm.LEAD_CONTACT_COUNTRY__C,
    u.NAME                                          AS OwnerId,
    cm.PRIMARY_PRODUCT_INTEREST__C,
    cm.OWNERID__C,
    cm.CAMPAIGN_BUSINESS_UNIT__C                    AS BusinessUnit,
    -- ✅ TIMESTAMP → CAST to DATE
    CAST(cm.CAMPAIGN_MEMBER_ASSIGNED_DATE__C AS DATE) AS CAMPAIGN_MEMBER_ASSIGNED_DATE__C,
    upc.NAME                                        AS UL_Parent_Name

FROM `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` c

LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN_MEMBER` cm
    ON c.ID = cm.CAMPAIGNID

LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_USER` u
    ON cm.OWNERID__C = u.ID

LEFT JOIN `prd-wiley-data.ODS_SFDC.T_S_SFDC_CAMPAIGN` upc
    ON upc.ID = c.ULTIMATE_PARENT_ID_STRING__C

WHERE
    -- ✅ FIX: TIMESTAMP → CAST to DATE for comparison with date literal
    CAST(cm.CAMPAIGN_MEMBER_ASSIGNED_DATE__C AS DATE) >= DATE '2024-05-01'
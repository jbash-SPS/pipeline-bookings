-- =============================================================================
-- Bookings ARR by Product Level 1
--
-- Monthly bookings ARR grouped by product category using the
-- PRODUCT_INFERENCE_HIERARCHY mapping (resource -> product category).
--
-- Sources:
--   PROD_PROVISIONING.FINANCE_SHARE.FACT_CONTRACT_LINE_BOOKINGS
--   PROD_PROVISIONING.FINANCE_SHARE.PRODUCT_INFERENCE_HIERARCHY
--   PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
--
-- Product categories:
--   Supplier Solutions, Analytics Solutions, Retailer Solutions,
--   Logistics Solutions, Revenue Solutions, Unmapped
-- =============================================================================

WITH
fx AS (
    SELECT
        CURRENCY_CODE AS currency,
        TO_CHAR(STARTING_DATE, 'YYYY-MM') AS month_key,
        1 / EXCHANGE_RATE AS rate
    FROM PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
)

SELECT
    COALESCE(pih.PRODUCT_CATEGORY, 'Unmapped')  AS product_level_1,
    LEFT(cl.ESTIMATED_CLOSE_DATE::varchar, 7)   AS month_closed,
    SUM(cl.BOOKINGS_ARR_ALLOCATED)               AS arr_usd,
    COUNT(*)                                      AS line_count
FROM PROD_PROVISIONING.FINANCE_SHARE.FACT_CONTRACT_LINE_BOOKINGS cl

LEFT JOIN PROD_PROVISIONING.FINANCE_SHARE.PRODUCT_INFERENCE_HIERARCHY pih
    ON pih.RESOURCE_NUMBER = cl.RESOURCE_NUMBER

WHERE cl.BOOKING = 'Booking'
    AND cl.DEAL_STAGE = 'Closed Won'
    AND cl.ESTIMATED_CLOSE_DATE >= '2020-01-01'

GROUP BY 1, 2

ORDER BY
    month_closed,
    arr_usd DESC;

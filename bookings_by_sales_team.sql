-- =============================================================================
-- Bookings ARR by Sales Team
--
-- Reconstructs the monthly ARR bookings by sales team report from Salesforce
-- source data. Replaces the manual Excel-based bookings management process.
--
-- Sources:
--   PROD_PROVISIONING.FINANCE_SHARE.DEALS_DATA
--   PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT
--   PROD_PROVISIONING.SALESFORCE.OPPORTUNITY
--   PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
--
-- Method:
--   Distributes each deal's ARR across teams using the Commissionable ARR
--   split percentages from OPPORTUNITY_SPLIT. Converts non-USD currencies
--   using monthly FX rates. Excludes rate reductions, negative adjustment
--   deals, and internal/admin teams.
--
-- Validated: Jan-Aug 2026 vs FINANCE_TEAM.ARR_BOOKINGS
--   104/134 team-months within +/-1%
--   5 teams perfect (8/8): Manufacturing, Retailer-Mid, SS-Analytics Europe,
--     Australia, SS-Analytics E&S
--   6 teams at 7/8: 1Screen, Asia, Retailer-Enterprise, SS-Analytics Mid,
--     SS-Emerging, SS-Enterprise
-- =============================================================================

WITH

-- Monthly FX rates from Business Central (1/EXCHANGE_RATE = local-currency-per-USD).
fx AS (
    SELECT
        CURRENCY_CODE AS currency,
        TO_CHAR(STARTING_DATE, 'YYYY-MM') AS month_key,
        1 / EXCHANGE_RATE AS rate
    FROM PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
),

-- Team name mapping: Salesforce internal names -> finance report names
nm(src, tgt) AS (
    SELECT * FROM VALUES
        ('Community Team',       'Community'),
        ('APAC - Australia',     'Australia'),
        ('APAC - Asia',          'Asia'),
        ('Retail - Enterprise',  'Retailer - Enterprise'),
        ('Retail - Mid Market',  'Retailer - Mid Market'),
        ('SS - Analytics Ent',   'SS - Analytics Enterprise'),
        ('SS - Analytics Mid',   'SS - Analytics Mid Market')
    AS t(src, tgt)
)

SELECT
    COALESCE(nm.tgt, os.EMPLOYEE_REPORTING_GROUP)   AS sales_team,
    d.MONTH_CLOSED,
    SUM(
        (CASE
            WHEN d.CURRENCY_CODE IN ('AUD', 'CAD', 'EUR')
            THEN d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE / f.rate
            ELSE d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE
        END)
        * os.SPLIT_PERCENTAGE / 100
    )                                                AS arr_usd
FROM PROD_PROVISIONING.FINANCE_SHARE.DEALS_DATA d

JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT os
    ON  os.OPPORTUNITY_ID = d.OPP_ID
    AND os.OPPORTUNITY_SPLIT_TYPE = 'Commissionable ARR'

JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY o
    ON o.OPPORTUNITY_ID = d.OPP_ID

LEFT JOIN fx f
    ON  f.currency = d.CURRENCY_CODE
    AND f.month_key = d.MONTH_CLOSED

LEFT JOIN nm
    ON nm.src = os.EMPLOYEE_REPORTING_GROUP

WHERE d.DEAL_STAGE = 'Closed Won'
    AND d.MONTH_CLOSED >= '2020-01'
    AND COALESCE(o.OPPORTUNITY_TYPE, '') <> 'Rate Reduction'
    AND COALESCE(d.BOOKING, '') <> 'Other'
    AND NOT (COALESCE(d.BOOKING, '') = ''
             AND d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE < 0)
    AND os.EMPLOYEE_REPORTING_GROUP NOT IN
        ('Do Not Report', 'System Admin', 'Customer Success', 'Revenue Recovery')

GROUP BY
    COALESCE(nm.tgt, os.EMPLOYEE_REPORTING_GROUP),
    d.MONTH_CLOSED

ORDER BY
    d.MONTH_CLOSED,
    arr_usd DESC;

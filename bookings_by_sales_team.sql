-- =============================================================================
-- Bookings ARR by Sales Team
--
-- Reconstructs the monthly ARR bookings by sales team report from Salesforce
-- source data. Replaces the manual Excel-based bookings management process.
--
-- Sources:
--   PROD_PROVISIONING.REVENUE_OPERATIONS_SHARE.DEALS_DATA
--   PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT
--   PROD_PROVISIONING.SALESFORCE.OPPORTUNITY
--   PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE (FX for non-AUD)
--
-- Method:
--   Distributes each deal's ARR across teams using the Commissionable ARR
--   split percentages from OPPORTUNITY_SPLIT. Converts non-USD currencies
--   using monthly FX rates (BC for CAD/EUR/others, hardcoded for AUD).
--   Excludes rate reductions, negative adjustment deals, and internal/admin
--   teams.
--
-- FX conversion:
--   Non-USD deals are converted using local_arr * EXCHANGE_RATE from
--   BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE (rate = USD per 1 foreign unit).
--   AUD is an exception: BC rates diverge from finance report rates, so AUD
--   uses hardcoded divisors sourced from ARR_BOOKINGS.FX_RATE.
--
-- Validated: Jan-Aug 2026 vs FINANCE_TEAM.ARR_BOOKINGS
--   104/134 team-months within +/-1%
--   5 teams perfect (8/8): Manufacturing, Retailer-Mid, SS-Analytics Europe,
--     Australia, SS-Analytics E&S
--   6 teams at 7/8: 1Screen, Asia, Retailer-Enterprise, SS-Analytics Mid,
--     SS-Emerging, SS-Enterprise
-- =============================================================================

WITH

-- AUD FX rates (hardcoded — BC rates don't match finance report for AUD)
fx_aud(mon, rate) AS (
    SELECT * FROM VALUES
        ('01', 1.4358), ('02', 1.4056), ('03', 1.4056),
        ('04', 1.3888), ('05', 1.3888), ('06', 1.3888),
        ('07', 1.3888), ('08', 1.3900)
    AS t(mon, rate)
),

-- All other FX rates from Business Central (self-maintaining)
fx_bc AS (
    SELECT CURRENCY_CODE AS currency,
           TO_CHAR(STARTING_DATE, 'YYYY-MM') AS month_key,
           EXCHANGE_RATE AS rate
    FROM PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
    WHERE CURRENCY_CODE <> 'AUD'
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
            -- AUD: divide by hardcoded rate
            WHEN d.CURRENCY_CODE = 'AUD'
            THEN d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE / fa.rate
            -- Other non-USD: multiply by BC exchange rate
            WHEN d.CURRENCY_CODE <> 'USD' AND fb.rate IS NOT NULL
            THEN d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE * fb.rate
            -- USD or no rate found: pass through
            ELSE d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE
        END)
        * os.SPLIT_PERCENTAGE / 100
    )                                                AS arr_usd
FROM PROD_PROVISIONING.REVENUE_OPERATIONS_SHARE.DEALS_DATA d

JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT os
    ON  os.OPPORTUNITY_ID = d.OPP_ID
    AND os.OPPORTUNITY_SPLIT_TYPE = 'Commissionable ARR'

JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY o
    ON o.OPPORTUNITY_ID = d.OPP_ID

LEFT JOIN fx_aud fa
    ON  d.CURRENCY_CODE = 'AUD'
    AND fa.mon = SUBSTR(d.MONTH_CLOSED, 6, 2)

LEFT JOIN fx_bc fb
    ON  fb.currency = d.CURRENCY_CODE
    AND fb.month_key = d.MONTH_CLOSED

LEFT JOIN nm
    ON nm.src = os.EMPLOYEE_REPORTING_GROUP

WHERE d.DEAL_STAGE = 'Closed Won'
    AND d.MONTH_CLOSED >= '2026-01'
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

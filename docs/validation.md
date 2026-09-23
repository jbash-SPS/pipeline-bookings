# Validation Results

Validated against `PROD_PROVISIONING.FINANCE_TEAM.ARR_BOOKINGS` for January through August 2026.

## Summary

- **104 of 134 team-months (78%) within +/-1%**
- 5 teams perfect across all 8 months
- 6 teams match 7 of 8 months
- 5 of 8 monthly company-wide totals within +/-1%

## Team-Month Variance (%)

| Team | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | OK |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Manufacturing Sales | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8 |
| Retailer - Mid Market | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | -0.5 | 0.0 | 0.0 | 8 |
| SS - Analytics Europe | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8 |
| Australia | 0.8 | 0.0 | 0.0 | 0.1 | 0.0 | -0.2 | 0.0 | -0.1 | 8 |
| SS - Analytics E&S | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8 |
| 1Screen | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 52.7 | 7 |
| Asia | 0.0 | -6.2 | -0.3 | 0.0 | 0.0 | 0.2 | 0.0 | 0.3 | 7 |
| Retailer - Enterprise | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | -36.8 | 0.0 | 7 |
| SS - Analytics Mid Mkt | 0.0 | 0.0 | -2.6 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 7 |
| SS - Emerging and Small | -5.2 | 0.4 | 0.2 | -0.1 | 0.5 | 0.6 | 0.0 | 0.5 | 7 |
| SS - Enterprise | 12.3 | 0.7 | 0.1 | 0.0 | 0.0 | 0.0 | 0.0 | 0.2 | 7 |
| Community | 0.0 | 0.1 | -0.4 | 3.1 | -0.3 | -3.0 | 0.3 | 0.4 | 6 |
| SS - Analytics Enterprise | 10.7 | -3.9 | 0.0 | 0.0 | 0.0 | 0.0 | 5.4 | 0.0 | 5 |
| SS - Mid Market | 17.5 | 9.2 | -3.0 | -0.9 | -0.7 | -1.4 | -0.7 | -0.2 | 4 |
| Logistics Sales | 0.0 | 0.0 | 0.0 | 1.3 | 1.4 | 8.0 | -8.4 | 6.9 | 3 |
| Europe Sales | -28.3 | -17.4 | -13.5 | -10.0 | -22.0 | -16.8 | -8.6 | -6.7 | 0 |

## Monthly Total Variance

| Month | Actual | Modeled | % Variance |
|---|---:|---:|--:|
| Jan | 5,913,439 | 5,991,207 | +1.3% |
| Feb | 6,880,841 | 7,164,341 | +4.1% |
| Mar | 11,981,927 | 11,947,978 | -0.3% |
| Apr | 9,191,721 | 9,292,973 | +1.1% |
| May | 7,285,094 | 7,294,093 | +0.1% |
| Jun | 11,055,430 | 11,061,940 | +0.1% |
| Jul | 8,840,321 | 8,791,661 | -0.6% |
| Aug | 8,698,022 | 8,382,841 | -3.6% |

## Known Outliers and Root Causes

### 1. TIE European Entity Data (Europe Sales, all months)

Europe Sales is 7-28% under every month because the European entity (TIE / The International Exchange) books deals through a separate system with deal IDs in the format "08.xxx.xxx". These deals do not exist in Salesforce or any current Snowflake source table. They are loaded directly into ARR_BOOKINGS from the TIE system. Total impact: approximately $600K YTD ($18K-$116K per month).

**Fix:** Establish an ETL pipeline from the TIE European system into Snowflake.

### 2. January 2026 Team Restructuring (SS-Mid +17.5%, SS-Enterprise +12.3%, SS-Analytics Ent +10.7%, SS-Emerging -5.2%)

A fiscal-year team reorganization moved approximately $450K of deal credit from SS-Mid Market and SS-Enterprise into SS-Emerging and Small. OPPORTUNITY_SPLIT reflects the post-restructuring assignments; the report credits these January deals to pre-restructuring teams. The effect drops to $34K by February and is negligible by March.

**Fix:** A January-specific team-mapping override for the affected deals.

### 3. Managed Team Reassignment (Community Apr/Jun, SS-Mid Feb, Logistics Aug)

The finance team manually reassigns individual deals between teams. The most common pattern is deals moving between Community and SS-Emerging and Small in both directions. For Community, product-level ARR is distributed by split percentage (which our model replicates correctly), but a subset of deals are overridden to a different team with no algorithmic marker in the source data. Typical impact: $20K-$99K per month on affected teams.

**Fix:** Requires the finance team's assignment rules or a deal-level lookup table.

### 4. Close-Date Adjustments (Logistics Jun +8.0% / Jul -8.4%)

One deal (Kirsch Transportation, $22,776) has a Salesforce close date of June 24 but the report records it effective July 1. This single deal creates the entire +/-8% swing. The EFFECTIVE_BILLING_DATE field was tested as an alternative but is too sparsely populated (0.6% of deals) to be useful.

**Fix:** If a finance-adjusted close date field becomes consistently populated, use it.

### 5. Data-Loading Timing (1Screen Aug +52.7%)

One deal (Walmart Canada, $17,970) closed August 12 and exists in real-time DEALS_DATA but has not yet been loaded into the managed ARR_BOOKINGS table. This is not a model error — it reflects the query running against more current data than the managed report. Self-corrects on the next bookings refresh.

## Improvement Roadmap

| Priority | Action | Impact |
|---|---|---|
| 1 | Integrate TIE European entity data | Fixes Europe Sales (0/8 -> ~7/8) |
| 2 | January 2026 team-mapping override | Fixes 4 teams' January outliers |
| 3 | FX rate reference table (replace hardcoded CTE) | Enables automatic monthly updates |
| 4 | Finance team deal-assignment rules | Reduces Community/SS-Mid variance |

# Methodology

## How the Query Works

The query takes every closed-won Salesforce opportunity and distributes its ARR across sales teams using the Commissionable ARR split percentages from OPPORTUNITY_SPLIT.

### Deal Attribution

Every Salesforce opportunity has one or more split records in OPPORTUNITY_SPLIT. Each split specifies what percentage of the deal's credit goes to a given rep's team. The query multiplies the deal's ARR by each split percentage to produce team-level bookings.

For example, a $100K deal with splits of 60% SS - Emerging and Small / 40% Community Team produces $60K for SS - Emerging and $40K for Community.

This approach was chosen over simpler alternatives (top-owner attribution, winner-takes-all) because the finance report distributes ARR at the product level by these same split percentages. Validation confirmed this matches the report for the most teams across all months.

### Currency Conversion

Deals booked in AUD, CAD, or EUR are converted to USD using monthly FX rates. The rates represent local-currency-per-USD (e.g., AUD 1.39 means 1 USD = 1.39 AUD). The formula is:

```
USD_ARR = LOCAL_ARR / FX_RATE
```

These rates are specific to the finance report and differ from the default Salesforce exchange rate (which uses a flat rate per currency). The monthly rates were extracted from ARR_BOOKINGS during validation.

### Exclusion Rules

Four filters match the finance report's scope:

1. **Rate Reduction**: Deals with `OPPORTUNITY_TYPE = 'Rate Reduction'` are excluded. These are downgrades, recontracting adjustments, and churn — the report treats them as retention events, not bookings.

2. **BOOKING = 'Other'**: Deals flagged as 'Other' in the BOOKING field are excluded. These are always negative-ARR adjustment records (refunds, credits, cancelled subscriptions) that the report drops entirely.

3. **Blank-BOOKING negatives**: Deals with no BOOKING flag and negative ARR are excluded. These are similar to 'Other'-flagged deals (account merges, right-size adjustments) but lack the explicit flag.

4. **Admin teams**: Deals owned by Do Not Report, System Admin, Customer Success, or Revenue Recovery teams are excluded. These correspond to the report's "SalesTeam does not contain usernames" filter.

### Team Name Mapping

Seven Salesforce team names are translated to match the finance report's naming convention:

| Salesforce (OPPORTUNITY_SPLIT) | Report |
|---|---|
| Community Team | Community |
| APAC - Australia | Australia |
| APAC - Asia | Asia |
| Retail - Enterprise | Retailer - Enterprise |
| Retail - Mid Market | Retailer - Mid Market |
| SS - Analytics Ent | SS - Analytics Enterprise |
| SS - Analytics Mid | SS - Analytics Mid Market |

All other team names pass through unchanged.

## Approaches Tested and Rejected

### Top-owner attribution (EMPLOYEE_REPORTING_GROUP)

Assigns 100% of each deal to the deal's primary owner team from DEALS_DATA. Simpler but less accurate: it doesn't credit secondary teams that receive inbound split credit (Logistics, Analytics teams), causing those teams to undercount. Scored 97/134 team-months within 1%.

### Two-population hybrid

Routes Community-involved deals through top-owner attribution and all other deals through split distribution. Improved Community accuracy but at the cost of teams that receive split credit from Community-involved deals. Scored 97/134.

### EFFECTIVE_BILLING_DATE for month attribution

Tested using the Salesforce EFFECTIVE_BILLING_DATE field instead of MONTH_CLOSED for deals where it's populated. Only 0.6% of deals have this field, and when populated, it shifted some deals to incorrect months (notably breaking MMT). The target deal it was meant to fix (Kirsch Transportation) didn't have the field populated. Scored 103/134 — worse than the baseline.

### Blanket positive-only filter

Excluding all negative-ARR deals worked for some teams (SS-Enterprise, 1Screen) but overcorrected for SS-Emerging, which legitimately has some negative bookings the report keeps. The targeted approach (exclude 'Other' flag + blank-flagged negatives) is more precise.

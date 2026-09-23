# Pipeline Bookings

Automated reconstruction of the monthly **ARR Bookings by Sales Team** report from Salesforce source data. Replaces the manual Excel-based bookings management process.

## What This Does

Takes every closed-won Salesforce opportunity and calculates how much ARR each sales team earned by month, matching the finance team's ARR by Sales Team report within 1% for most team-months.

The query distributes each deal's ARR across teams using Salesforce opportunity split percentages, converts non-USD currencies at monthly FX rates, and applies the same exclusion rules the finance report uses.

## Files

| File | Description |
|---|---|
| `bookings_by_sales_team.sql` | The main query |
| `docs/methodology.md` | Detailed methodology and business logic |
| `docs/validation.md` | Validation results and known variances |

## Accuracy

Validated against `FINANCE_TEAM.ARR_BOOKINGS` for January through August 2026:

- **104 of 134 team-months (78%) within +/-1%**
- 5 teams perfect across all 8 months
- 6 teams match 7 of 8 months
- 5 of 8 monthly totals within +/-1%

## Source Tables

| Table | Purpose |
|---|---|
| `PROD_PROVISIONING.REVENUE_OPERATIONS_SHARE.DEALS_DATA` | Closed-won opportunities with ARR, team, close date |
| `PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT` | Credit distribution by rep/team (Commissionable ARR) |
| `PROD_PROVISIONING.SALESFORCE.OPPORTUNITY` | Opportunity type (Rate Reduction filter) |

## Quick Start

Run `bookings_by_sales_team.sql` in Snowflake. Adjust the date range in the WHERE clause:

```sql
AND d.MONTH_CLOSED >= '2026-01'   -- change to desired start month
```

The FX rate CTE should be updated monthly when new rates are published. In production, replace it with a reference table.

import streamlit as st
import pandas as pd
import altair as alt
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Bookings Forecast", layout="wide")

# ============================================================================
# Sidebar
# ============================================================================
st.sidebar.title("Bookings Forecast")
page = st.sidebar.radio("Navigate", ["Forecast Overview", "Team Breakdown", "Model Health"])

# ============================================================================
# Data loading (cached)
# ============================================================================
@st.cache_data(ttl=3600)
def load_forecast():
    return session.sql("""
        SELECT * FROM FORECAST_RESULTS
        WHERE RUN_DATE = (SELECT MAX(RUN_DATE) FROM FORECAST_RESULTS)
        ORDER BY GRAIN, SEGMENT, PERIOD_DATE
    """).to_pandas()

@st.cache_data(ttl=3600)
def load_actuals():
    return session.sql("""
        WITH fx AS (
            SELECT CURRENCY_CODE AS currency, TO_CHAR(STARTING_DATE, 'YYYY-MM') AS month_key, 1 / EXCHANGE_RATE AS rate
            FROM PROD_PROVISIONING.BUSINESS_CENTRAL.CURRENCY_EXCHANGE_RATE
        ),
        nm(src, tgt) AS (
            SELECT * FROM VALUES
                ('Community Team','Community'),('APAC - Australia','Australia'),('APAC - Asia','Asia'),
                ('Retail - Enterprise','Retailer - Enterprise'),('Retail - Mid Market','Retailer - Mid Market'),
                ('SS - Analytics Ent','SS - Analytics Enterprise'),('SS - Analytics Mid','SS - Analytics Mid Market')
            AS t(src, tgt)
        )
        SELECT d.MONTH_CLOSED, SUM(
            (CASE WHEN d.CURRENCY_CODE IN ('AUD','CAD','EUR')
                  THEN d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE / f.rate
                  ELSE d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE END)
            * os.SPLIT_PERCENTAGE / 100
        ) AS ARR_USD
        FROM PROD_PROVISIONING.FINANCE_SHARE.DEALS_DATA d
        JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT os
            ON os.OPPORTUNITY_ID = d.OPP_ID AND os.OPPORTUNITY_SPLIT_TYPE = 'Commissionable ARR'
        JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY o
            ON o.OPPORTUNITY_ID = d.OPP_ID
        LEFT JOIN fx f ON f.currency = d.CURRENCY_CODE AND f.month_key = d.MONTH_CLOSED
        LEFT JOIN nm ON nm.src = os.EMPLOYEE_REPORTING_GROUP
        WHERE d.DEAL_STAGE = 'Closed Won'
            AND d.MONTH_CLOSED >= '2024-01'
            AND COALESCE(o.OPPORTUNITY_TYPE, '') <> 'Rate Reduction'
            AND COALESCE(d.BOOKING, '') <> 'Other'
            AND NOT (COALESCE(d.BOOKING, '') = '' AND d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE < 0)
            AND os.EMPLOYEE_REPORTING_GROUP NOT IN
                ('Do Not Report', 'System Admin', 'Customer Success', 'Revenue Recovery')
        GROUP BY 1 ORDER BY 1
    """).to_pandas()

@st.cache_data(ttl=3600)
def load_health():
    return session.sql("""
        SELECT * FROM FORECAST_MODEL_HEALTH
        WHERE RUN_DATE = (SELECT MAX(RUN_DATE) FROM FORECAST_MODEL_HEALTH)
    """).to_pandas()

@st.cache_data(ttl=3600)
def load_accuracy():
    return session.sql("""
        SELECT * FROM FORECAST_ACCURACY_SUMMARY
        WHERE SCORED_DATE = (SELECT MAX(SCORED_DATE) FROM FORECAST_ACCURACY_SUMMARY)
        ORDER BY MODEL, HORIZON
    """).to_pandas()

forecast_df = load_forecast()
run_date = forecast_df['RUN_DATE'].iloc[0] if len(forecast_df) > 0 else "N/A"
st.sidebar.caption(f"Last run: {run_date}")

# ============================================================================
# PAGE 1: FORECAST OVERVIEW
# ============================================================================
if page == "Forecast Overview":
    st.title("Forecast Overview")

    agg = forecast_df[forecast_df['GRAIN'] == 'aggregate'].copy()
    actuals = load_actuals()

    # Metric cards
    if len(agg) > 0:
        next_month = agg.iloc[0]
        next_q = agg.iloc[:3]['PREDICTED_ARR'].sum()
        full_year = agg['PREDICTED_ARR'].sum()

        c1, c2, c3 = st.columns(3)
        c1.metric("Next Month", f"${next_month['PREDICTED_ARR']/1e6:.1f}M",
                   help=f"{next_month['PERIOD_DATE']}")
        c2.metric("Next Quarter", f"${next_q/1e6:.1f}M")
        c3.metric("12-Month Total", f"${full_year/1e6:.1f}M")

    # Combined chart: actuals + forecast
    act_chart = actuals.copy()
    act_chart['DATE'] = pd.to_datetime(act_chart['MONTH_CLOSED'] + '-01')
    act_chart['TYPE'] = 'Actual'
    act_chart = act_chart.rename(columns={'ARR_USD': 'ARR'})

    fc_chart = agg[['PERIOD_DATE', 'PREDICTED_ARR']].copy()
    fc_chart['DATE'] = pd.to_datetime(fc_chart['PERIOD_DATE'])
    fc_chart['TYPE'] = 'Forecast'
    fc_chart = fc_chart.rename(columns={'PREDICTED_ARR': 'ARR'})

    combined = pd.concat([act_chart[['DATE', 'ARR', 'TYPE']], fc_chart[['DATE', 'ARR', 'TYPE']]])

    chart = alt.Chart(combined).mark_line(point=True).encode(
        x=alt.X('DATE:T', title='Month'),
        y=alt.Y('ARR:Q', title='ARR (USD)', axis=alt.Axis(format='$,.0f')),
        color=alt.Color('TYPE:N', scale=alt.Scale(domain=['Actual', 'Forecast'], range=['#4c78a8', '#e45756'])),
        strokeDash=alt.condition(alt.datum.TYPE == 'Forecast', alt.value([5, 3]), alt.value([0]))
    ).properties(width='container', height=400, title='Monthly Bookings ARR: Actual vs Forecast')

    st.altair_chart(chart, use_container_width=True)

    # Model components
    show_components = st.checkbox("Show individual model predictions")
    if show_components and len(agg) > 0:
        comp_data = []
        for _, row in agg.iterrows():
            d = pd.to_datetime(row['PERIOD_DATE'])
            for model in ['ARIMA_PRED', 'ETS_PRED', 'PROPHET_PRED', 'XGBOOST_PRED']:
                if pd.notna(row[model]):
                    comp_data.append({'DATE': d, 'ARR': row[model], 'Model': model.replace('_PRED', '')})
            comp_data.append({'DATE': d, 'ARR': row['PREDICTED_ARR'], 'Model': 'ENSEMBLE'})

        comp_df = pd.DataFrame(comp_data)
        comp_chart = alt.Chart(comp_df).mark_line(point=True).encode(
            x='DATE:T', y=alt.Y('ARR:Q', axis=alt.Axis(format='$,.0f')),
            color='Model:N', strokeDash=alt.condition(alt.datum.Model == 'ENSEMBLE', alt.value([0]), alt.value([3, 3]))
        ).properties(width='container', height=350, title='Model Components')
        st.altair_chart(comp_chart, use_container_width=True)

# ============================================================================
# PAGE 2: TEAM BREAKDOWN
# ============================================================================
elif page == "Team Breakdown":
    st.title("Team Breakdown")

    teams_df = forecast_df[forecast_df['GRAIN'] == 'team'].copy()

    if len(teams_df) > 0:
        all_teams = sorted(teams_df['SEGMENT'].unique())
        selected = st.multiselect("Filter teams", all_teams, default=all_teams[:10])

        filtered = teams_df[teams_df['SEGMENT'].isin(selected)]

        # Stacked bar
        bar_data = filtered[['PERIOD_DATE', 'SEGMENT', 'PREDICTED_ARR']].copy()
        bar_data['PERIOD_DATE'] = pd.to_datetime(bar_data['PERIOD_DATE'])

        bar_chart = alt.Chart(bar_data).mark_bar().encode(
            x=alt.X('PERIOD_DATE:T', title='Month'),
            y=alt.Y('PREDICTED_ARR:Q', title='ARR (USD)', axis=alt.Axis(format='$,.0f')),
            color=alt.Color('SEGMENT:N', legend=alt.Legend(columns=2)),
            tooltip=['SEGMENT', alt.Tooltip('PREDICTED_ARR:Q', format='$,.0f'), 'PERIOD_DATE:T']
        ).properties(width='container', height=450, title='Forecasted ARR by Team')

        st.altair_chart(bar_chart, use_container_width=True)

        # Table
        pivot = filtered.pivot_table(index='SEGMENT', columns='PERIOD_DATE', values='PREDICTED_ARR', aggfunc='sum')
        pivot.columns = [c.strftime('%Y-%m') if hasattr(c, 'strftime') else str(c)[:7] for c in pivot.columns]
        st.dataframe(pivot.style.format("${:,.0f}"), use_container_width=True)

        # Reconciliation factors
        recon = filtered[['PERIOD_DATE', 'RECONCILIATION_FACTOR']].drop_duplicates()
        with st.expander("Reconciliation factors"):
            st.dataframe(recon, use_container_width=True)
    else:
        st.info("No team-level forecasts found.")

# ============================================================================
# PAGE 3: MODEL HEALTH
# ============================================================================
elif page == "Model Health":
    st.title("Model Health & Accuracy")

    # Health status
    health = load_health()
    if len(health) > 0:
        st.subheader("Latest Run Status")
        for _, row in health.iterrows():
            status_icon = "OK" if row['STATUS'] == 'success' else "WARN"
            runtime = f"{row['RUNTIME_SECONDS']:.1f}s" if pd.notna(row['RUNTIME_SECONDS']) else "N/A"
            params = row.get('ARIMA_PARAMS', '')
            st.text(f"  [{status_icon}] {row['MODEL']:10s}  {runtime:>6s}  {params or ''}")

        failed = health[~health['STATUS'].str.startswith('success')]
        if len(failed) > 0:
            st.warning(f"{len(failed)} model(s) failed in the latest run. Ensemble may be degraded.")
    else:
        st.info("No health data yet.")

    # Accuracy
    accuracy = load_accuracy()
    if len(accuracy) > 0:
        st.subheader("WMAPE by Model and Horizon")

        pivot_acc = accuracy.pivot_table(index='HORIZON', columns='MODEL', values='WMAPE_PCT')
        if 'ensemble' in pivot_acc.columns:
            col_order = ['ensemble'] + [c for c in sorted(pivot_acc.columns) if c != 'ensemble']
            pivot_acc = pivot_acc[col_order]

        acc_chart = alt.Chart(accuracy).mark_line(point=True).encode(
            x=alt.X('HORIZON:O', title='Forecast Horizon (months)'),
            y=alt.Y('WMAPE_PCT:Q', title='WMAPE (%)'),
            color='MODEL:N'
        ).properties(width='container', height=350, title='Forecast Accuracy by Horizon')

        st.altair_chart(acc_chart, use_container_width=True)
        st.dataframe(pivot_acc.round(1), use_container_width=True)
    else:
        st.info("No accuracy data yet. Accuracy scoring runs after forecasts mature.")

    # Historical forecast vs actual
    scored_rows = session.sql("""
        SELECT PERIOD_DATE, PREDICTED_ARR, ACTUAL_ARR
        FROM FORECAST_RESULTS
        WHERE GRAIN = 'aggregate' AND ACTUAL_ARR IS NOT NULL
        ORDER BY RUN_DATE DESC, PERIOD_DATE
        LIMIT 100
    """).to_pandas()

    if len(scored_rows) > 0:
        st.subheader("Forecast vs Actual (Matured Months)")
        scatter = alt.Chart(scored_rows).mark_circle(size=60).encode(
            x=alt.X('ACTUAL_ARR:Q', title='Actual ARR', axis=alt.Axis(format='$,.0f')),
            y=alt.Y('PREDICTED_ARR:Q', title='Predicted ARR', axis=alt.Axis(format='$,.0f')),
            tooltip=['PERIOD_DATE', alt.Tooltip('ACTUAL_ARR:Q', format='$,.0f'), alt.Tooltip('PREDICTED_ARR:Q', format='$,.0f')]
        ).properties(width=500, height=400)

        line = alt.Chart(pd.DataFrame({'x': [scored_rows['ACTUAL_ARR'].min(), scored_rows['ACTUAL_ARR'].max()]})).mark_rule(
            strokeDash=[5, 3], color='gray'
        ).encode(x='x:Q', y='x:Q')

        st.altair_chart(scatter + line, use_container_width=True)

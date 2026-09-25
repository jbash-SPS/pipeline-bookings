-- =============================================================================
-- Ensemble Forecast Pipeline — DDL
-- Creates tables, stored procedure, and weekly task.
-- =============================================================================
USE ROLE PROD_FINANCE_FULLACCESS_ROLE;
USE WAREHOUSE FINANCE_WH;
USE DATABASE PROD_PROVISIONING;
USE SCHEMA FINANCE_SHARE;

-- ============================================================================
-- 1. TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS FORECAST_RESULTS (
    RUN_DATE              DATE         NOT NULL,
    GRAIN                 VARCHAR(20)  NOT NULL,  -- 'aggregate' or 'team'
    SEGMENT               VARCHAR(100) NOT NULL,  -- 'ALL' or team name
    PERIOD_DATE           DATE         NOT NULL,
    HORIZON               INT          NOT NULL,
    PREDICTED_ARR         FLOAT,
    ARIMA_PRED            FLOAT,
    ETS_PRED              FLOAT,
    PROPHET_PRED          FLOAT,
    XGBOOST_PRED          FLOAT,
    ACTUAL_ARR            FLOAT,
    RECONCILIATION_FACTOR FLOAT
);

CREATE TABLE IF NOT EXISTS FORECAST_MODEL_HEALTH (
    RUN_DATE          DATE        NOT NULL,
    MODEL             VARCHAR(20) NOT NULL,
    STATUS            VARCHAR(20) NOT NULL,
    ARIMA_PARAMS      VARCHAR(100),
    TRAINING_MONTHS   INT,
    RUNTIME_SECONDS   FLOAT
);

CREATE TABLE IF NOT EXISTS FORECAST_ACCURACY_SUMMARY (
    SCORED_DATE  DATE        NOT NULL,
    MODEL        VARCHAR(20) NOT NULL,
    HORIZON      INT         NOT NULL,
    WMAPE_PCT    FLOAT,
    BIAS_PCT     FLOAT,
    N_PERIODS    INT
);

-- ============================================================================
-- 2. STORED PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE FORECAST_PIPELINE_RUN()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pandas', 'numpy', 'pmdarima', 'statsmodels', 'prophet', 'lightgbm')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import pandas as pd
import numpy as np
import time
import warnings
warnings.filterwarnings('ignore')

def run(session):
    from datetime import date, timedelta
    run_date = date.today()

    # =====================================================================
    # STEP A: ACCURACY SCORING — fill actuals for matured forecasts
    # =====================================================================
    actuals_query = """
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
    SELECT
        COALESCE(nm.tgt, os.EMPLOYEE_REPORTING_GROUP) AS sales_team,
        d.MONTH_CLOSED,
        SUM(
            (CASE WHEN d.CURRENCY_CODE IN ('AUD','CAD','EUR')
                  THEN d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE / f.rate
                  ELSE d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE END)
            * os.SPLIT_PERCENTAGE / 100
        ) AS arr_usd
    FROM PROD_PROVISIONING.FINANCE_SHARE.DEALS_DATA d
    JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY_SPLIT os
        ON os.OPPORTUNITY_ID = d.OPP_ID AND os.OPPORTUNITY_SPLIT_TYPE = 'Commissionable ARR'
    JOIN PROD_PROVISIONING.SALESFORCE.OPPORTUNITY o
        ON o.OPPORTUNITY_ID = d.OPP_ID
    LEFT JOIN fx f ON f.currency = d.CURRENCY_CODE AND f.month_key = d.MONTH_CLOSED
    LEFT JOIN nm ON nm.src = os.EMPLOYEE_REPORTING_GROUP
    WHERE d.DEAL_STAGE = 'Closed Won'
        AND d.MONTH_CLOSED >= '2020-01'
        AND COALESCE(o.OPPORTUNITY_TYPE, '') <> 'Rate Reduction'
        AND COALESCE(d.BOOKING, '') <> 'Other'
        AND NOT (COALESCE(d.BOOKING, '') = '' AND d.BOOKINGS_ANNUALIZED_RECURRING_REVENUE < 0)
        AND os.EMPLOYEE_REPORTING_GROUP NOT IN
            ('Do Not Report', 'System Admin', 'Customer Success', 'Revenue Recovery')
    GROUP BY 1, 2
    ORDER BY 1, 2
    """
    actuals_df = session.sql(actuals_query).to_pandas()
    actuals_df['MONTH_CLOSED'] = actuals_df['MONTH_CLOSED'].astype(str)

    # Aggregate actuals by month
    agg_actuals = actuals_df.groupby('MONTH_CLOSED')['ARR_USD'].sum().reset_index()
    agg_actuals.columns = ['MONTH_CLOSED', 'ACTUAL_TOTAL']

    # Team actuals
    team_actuals = actuals_df.copy()

    # Fill actuals for matured forecasts (15-day maturity gate)
    maturity_cutoff = (run_date - timedelta(days=15)).strftime('%Y-%m')
    session.sql(f"""
        UPDATE FORECAST_RESULTS fr
        SET ACTUAL_ARR = act.actual_arr
        FROM (
            SELECT MONTH_CLOSED, SUM(ARR_USD) actual_arr
            FROM ({actuals_query}) GROUP BY 1
        ) act
        WHERE fr.ACTUAL_ARR IS NULL
          AND fr.GRAIN = 'aggregate'
          AND TO_CHAR(fr.PERIOD_DATE, 'YYYY-MM') = act.MONTH_CLOSED
          AND act.MONTH_CLOSED <= '{maturity_cutoff}'
    """).collect()

    session.sql(f"""
        UPDATE FORECAST_RESULTS fr
        SET ACTUAL_ARR = act.actual_arr
        FROM (
            SELECT SALES_TEAM, MONTH_CLOSED, SUM(ARR_USD) actual_arr
            FROM ({actuals_query}) GROUP BY 1, 2
        ) act
        WHERE fr.ACTUAL_ARR IS NULL
          AND fr.GRAIN = 'team'
          AND fr.SEGMENT = act.SALES_TEAM
          AND TO_CHAR(fr.PERIOD_DATE, 'YYYY-MM') = act.MONTH_CLOSED
          AND act.MONTH_CLOSED <= '{maturity_cutoff}'
    """).collect()

    # Write accuracy summary
    scored = session.sql("""
        SELECT 'ensemble' MODEL, HORIZON,
            ROUND(DIV0(SUM(ABS(PREDICTED_ARR - ACTUAL_ARR)), SUM(ACTUAL_ARR))*100, 1) WMAPE_PCT,
            ROUND((DIV0(SUM(PREDICTED_ARR), SUM(ACTUAL_ARR))-1)*100, 1) BIAS_PCT,
            COUNT(*) N_PERIODS
        FROM FORECAST_RESULTS WHERE ACTUAL_ARR IS NOT NULL AND GRAIN = 'aggregate'
        GROUP BY 2
        UNION ALL
        SELECT 'arima', HORIZON,
            ROUND(DIV0(SUM(ABS(ARIMA_PRED - ACTUAL_ARR)), SUM(ACTUAL_ARR))*100, 1),
            ROUND((DIV0(SUM(ARIMA_PRED), SUM(ACTUAL_ARR))-1)*100, 1), COUNT(*)
        FROM FORECAST_RESULTS WHERE ACTUAL_ARR IS NOT NULL AND GRAIN = 'aggregate'
        GROUP BY 2
        UNION ALL
        SELECT 'ets', HORIZON,
            ROUND(DIV0(SUM(ABS(ETS_PRED - ACTUAL_ARR)), SUM(ACTUAL_ARR))*100, 1),
            ROUND((DIV0(SUM(ETS_PRED), SUM(ACTUAL_ARR))-1)*100, 1), COUNT(*)
        FROM FORECAST_RESULTS WHERE ACTUAL_ARR IS NOT NULL AND GRAIN = 'aggregate'
        GROUP BY 2
        UNION ALL
        SELECT 'prophet', HORIZON,
            ROUND(DIV0(SUM(ABS(PROPHET_PRED - ACTUAL_ARR)), SUM(ACTUAL_ARR))*100, 1),
            ROUND((DIV0(SUM(PROPHET_PRED), SUM(ACTUAL_ARR))-1)*100, 1), COUNT(*)
        FROM FORECAST_RESULTS WHERE ACTUAL_ARR IS NOT NULL AND GRAIN = 'aggregate' AND PROPHET_PRED IS NOT NULL
        GROUP BY 2
        UNION ALL
        SELECT 'xgboost', HORIZON,
            ROUND(DIV0(SUM(ABS(XGBOOST_PRED - ACTUAL_ARR)), SUM(ACTUAL_ARR))*100, 1),
            ROUND((DIV0(SUM(XGBOOST_PRED), SUM(ACTUAL_ARR))-1)*100, 1), COUNT(*)
        FROM FORECAST_RESULTS WHERE ACTUAL_ARR IS NOT NULL AND GRAIN = 'aggregate'
        GROUP BY 2
    """).to_pandas()
    if len(scored) > 0:
        scored['SCORED_DATE'] = run_date
        session.sql(f"DELETE FROM FORECAST_ACCURACY_SUMMARY WHERE SCORED_DATE = '{run_date}'").collect()
        session.create_dataframe(scored).write.mode('append').save_as_table('FORECAST_ACCURACY_SUMMARY')

    # =====================================================================
    # STEP B: BUILD AGGREGATE MONTHLY SERIES
    # =====================================================================
    series_data = agg_actuals.copy()
    series_data = series_data.sort_values('MONTH_CLOSED')
    series_vals = series_data['ACTUAL_TOTAL'].values.astype(float)
    series_dates = pd.to_datetime(series_data['MONTH_CLOSED'] + '-01')

    FORECAST_MONTHS = 12
    models_output = {}
    health_rows = []

    # =====================================================================
    # STEP C: FIT 4 MODELS ON AGGREGATE
    # =====================================================================
    import pmdarima as pm
    from statsmodels.tsa.holtwinters import ExponentialSmoothing
    from prophet import Prophet
    import lightgbm as lgb

    # ARIMA
    t0 = time.time()
    try:
        arima_model = pm.auto_arima(series_vals, seasonal=True, m=12, suppress_warnings=True,
                                     stepwise=True, error_action='ignore',
                                     max_p=3, max_q=3, max_P=2, max_Q=2, max_d=2, max_D=1)
        arima_fc = np.maximum(arima_model.predict(n_periods=FORECAST_MONTHS), 0)
        arima_params = f"({arima_model.order[0]},{arima_model.order[1]},{arima_model.order[2]})({arima_model.seasonal_order[0]},{arima_model.seasonal_order[1]},{arima_model.seasonal_order[2]})[12]"
        models_output['arima'] = arima_fc
        health_rows.append({'MODEL': 'arima', 'STATUS': 'success', 'ARIMA_PARAMS': arima_params,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})
    except Exception as e:
        models_output['arima'] = np.full(FORECAST_MONTHS, np.nan)
        health_rows.append({'MODEL': 'arima', 'STATUS': f'failed: {str(e)[:80]}', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})

    # ETS
    t0 = time.time()
    try:
        ets_model = ExponentialSmoothing(series_vals, seasonal_periods=12, trend='add', seasonal='mul',
                                          initialization_method='estimated').fit(optimized=True)
        ets_fc = np.maximum(ets_model.forecast(FORECAST_MONTHS), 0)
        models_output['ets'] = ets_fc
        health_rows.append({'MODEL': 'ets', 'STATUS': 'success', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})
    except Exception as e:
        try:
            ets_model = ExponentialSmoothing(series_vals, seasonal_periods=12, trend='add', seasonal='add',
                                              initialization_method='estimated').fit(optimized=True)
            ets_fc = np.maximum(ets_model.forecast(FORECAST_MONTHS), 0)
            models_output['ets'] = ets_fc
            health_rows.append({'MODEL': 'ets', 'STATUS': 'success (additive fallback)', 'ARIMA_PARAMS': None,
                               'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})
        except Exception as e2:
            models_output['ets'] = np.full(FORECAST_MONTHS, np.nan)
            health_rows.append({'MODEL': 'ets', 'STATUS': f'failed: {str(e2)[:80]}', 'ARIMA_PARAMS': None,
                               'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})

    # Prophet
    t0 = time.time()
    try:
        pdf = pd.DataFrame({'ds': series_dates, 'y': series_vals})
        prophet_model = Prophet(yearly_seasonality=True, weekly_seasonality=False,
                                daily_seasonality=False, seasonality_mode='multiplicative')
        prophet_model.fit(pdf)
        future = prophet_model.make_future_dataframe(periods=FORECAST_MONTHS, freq='MS')
        pred = prophet_model.predict(future)
        prophet_fc = np.maximum(pred['yhat'].iloc[-FORECAST_MONTHS:].values, 0)
        models_output['prophet'] = prophet_fc
        health_rows.append({'MODEL': 'prophet', 'STATUS': 'success', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})
    except Exception as e:
        models_output['prophet'] = np.full(FORECAST_MONTHS, np.nan)
        health_rows.append({'MODEL': 'prophet', 'STATUS': f'failed: {str(e)[:80]}', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})

    # XGBoost
    t0 = time.time()
    try:
        def make_xgb_features(vals):
            df = pd.DataFrame({'y': vals})
            for lag in [1, 2, 3, 6, 12]:
                df[f'lag_{lag}'] = df['y'].shift(lag)
            df['month'] = [(i % 12) + 1 for i in range(len(df))]
            df['quarter_end'] = df['month'].isin([3, 6, 9, 12]).astype(int)
            return df.dropna()

        feat_df = make_xgb_features(series_vals)
        X_train = feat_df.drop('y', axis=1)
        y_train = feat_df['y']
        xgb_model = lgb.LGBMRegressor(n_estimators=200, learning_rate=0.1, max_depth=4,
                                        num_leaves=15, verbose=-1, random_state=42)
        xgb_model.fit(X_train, y_train)

        history = list(series_vals)
        xgb_preds = []
        for step in range(FORECAST_MONTHS):
            row = {}
            for lag in [1, 2, 3, 6, 12]:
                row[f'lag_{lag}'] = history[-lag] if lag <= len(history) else 0
            next_month = ((len(series_vals) + step) % 12) + 1
            row['month'] = next_month
            row['quarter_end'] = int(next_month in [3, 6, 9, 12])
            pred = max(xgb_model.predict(pd.DataFrame([row]))[0], 0)
            xgb_preds.append(pred)
            history.append(pred)

        models_output['xgboost'] = np.array(xgb_preds)
        health_rows.append({'MODEL': 'xgboost', 'STATUS': 'success', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})
    except Exception as e:
        models_output['xgboost'] = np.full(FORECAST_MONTHS, np.nan)
        health_rows.append({'MODEL': 'xgboost', 'STATUS': f'failed: {str(e)[:80]}', 'ARIMA_PARAMS': None,
                           'TRAINING_MONTHS': len(series_vals), 'RUNTIME_SECONDS': round(time.time()-t0, 1)})

    # Ensemble
    valid = [v for v in models_output.values() if not np.isnan(v).any()]
    ensemble_fc = np.mean(valid, axis=0) if valid else np.full(FORECAST_MONTHS, np.nan)

    # Build forecast dates
    last_month = pd.Timestamp(series_data['MONTH_CLOSED'].iloc[-1] + '-01')
    forecast_dates = pd.date_range(last_month + pd.DateOffset(months=1), periods=FORECAST_MONTHS, freq='MS')

    # =====================================================================
    # STEP D: PER-TEAM ARIMA
    # =====================================================================
    team_series = actuals_df.pivot_table(index='MONTH_CLOSED', columns='SALES_TEAM', values='ARR_USD', aggfunc='sum').fillna(0)
    team_series = team_series.sort_index()
    active_teams = [t for t in team_series.columns if team_series[t].iloc[-12:].sum() > 0]

    team_forecasts = {}
    for team in active_teams:
        vals = team_series[team].values.astype(float)
        try:
            m = pm.auto_arima(vals, seasonal=True, m=12, suppress_warnings=True, stepwise=True,
                              error_action='ignore', max_p=2, max_q=2, max_P=1, max_Q=1)
            team_forecasts[team] = np.maximum(m.predict(n_periods=FORECAST_MONTHS), 0)
        except:
            team_forecasts[team] = np.full(FORECAST_MONTHS, max(vals[-12:].mean(), 0))

    # =====================================================================
    # STEP E: RECONCILE — scale per-team to sum to ensemble
    # =====================================================================
    team_raw_sums = np.zeros(FORECAST_MONTHS)
    for fc in team_forecasts.values():
        team_raw_sums += fc

    recon_factors = np.where(team_raw_sums > 0, ensemble_fc / team_raw_sums, 1.0)

    # =====================================================================
    # STEP F: WRITE RESULTS
    # =====================================================================
    # Delete any existing rows for this run_date (idempotent)
    session.sql(f"DELETE FROM FORECAST_RESULTS WHERE RUN_DATE = '{run_date}'").collect()
    session.sql(f"DELETE FROM FORECAST_MODEL_HEALTH WHERE RUN_DATE = '{run_date}'").collect()

    # Aggregate rows
    agg_rows = []
    for h in range(FORECAST_MONTHS):
        agg_rows.append({
            'RUN_DATE': run_date,
            'GRAIN': 'aggregate',
            'SEGMENT': 'ALL',
            'PERIOD_DATE': forecast_dates[h].date(),
            'HORIZON': h + 1,
            'PREDICTED_ARR': float(ensemble_fc[h]),
            'ARIMA_PRED': float(models_output['arima'][h]) if not np.isnan(models_output['arima'][h]) else None,
            'ETS_PRED': float(models_output['ets'][h]) if not np.isnan(models_output['ets'][h]) else None,
            'PROPHET_PRED': float(models_output['prophet'][h]) if not np.isnan(models_output['prophet'][h]) else None,
            'XGBOOST_PRED': float(models_output['xgboost'][h]) if not np.isnan(models_output['xgboost'][h]) else None,
            'ACTUAL_ARR': None,
            'RECONCILIATION_FACTOR': None
        })

    # Team rows
    team_rows = []
    for team, fc in team_forecasts.items():
        for h in range(FORECAST_MONTHS):
            team_rows.append({
                'RUN_DATE': run_date,
                'GRAIN': 'team',
                'SEGMENT': team,
                'PERIOD_DATE': forecast_dates[h].date(),
                'HORIZON': h + 1,
                'PREDICTED_ARR': float(fc[h] * recon_factors[h]),
                'ARIMA_PRED': float(fc[h]),
                'ETS_PRED': None,
                'PROPHET_PRED': None,
                'XGBOOST_PRED': None,
                'ACTUAL_ARR': None,
                'RECONCILIATION_FACTOR': float(recon_factors[h])
            })

    all_rows = agg_rows + team_rows
    results_df = pd.DataFrame(all_rows)
    session.create_dataframe(results_df).write.mode('append').save_as_table('FORECAST_RESULTS')

    # Model health
    health_df = pd.DataFrame(health_rows)
    health_df['RUN_DATE'] = run_date
    session.create_dataframe(health_df).write.mode('append').save_as_table('FORECAST_MODEL_HEALTH')

    n_teams = len(team_forecasts)
    n_models = sum(1 for v in models_output.values() if not np.isnan(v).any())
    return f"Forecast complete: {n_models}/4 models, {n_teams} teams, {len(all_rows)} rows written for {run_date}"
$$;

-- ============================================================================
-- 3. WEEKLY TASK
-- ============================================================================

CREATE OR REPLACE TASK FORECAST_WEEKLY_RUN
  WAREHOUSE = 'FINANCE_WH'
  SCHEDULE = 'USING CRON 0 2 * * 0 America/Chicago'
  COMMENT = 'Weekly ensemble bookings forecast — runs Sunday 2 AM CT'
AS
  CALL FORECAST_PIPELINE_RUN();

-- Task is created in suspended state. Enable with:
-- ALTER TASK FORECAST_WEEKLY_RUN RESUME;

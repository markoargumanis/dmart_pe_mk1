DECLARE current_month DATE;

-- Si es 1ro del mes, usar el mes anterior. Sino, el mes actual.
SET current_month = 
IF(
  EXTRACT(DAY FROM CURRENT_DATE()) <= 3,
  DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), MONTH),
  DATE_TRUNC(CURRENT_DATE(), MONTH)
);

INSERT INTO `peya-peru.automated_tables_reports.dmart_fact_orders_mini_order_level`

WITH
  -- =================================================================================
  -- 1. CTEs DE FUENTES Y NORMALIZACIÓN DE TIPOS (MÉTODO DE COLUMNAS PARALELAS)
  -- Se preserva el tipo nativo para el output y se crea una columna 'join_' en STRING para velocidad.
  -- =================================================================================
  src_first_dmart_order_date_users AS (
    SELECT 
      customer_id, CAST(customer_id AS STRING) AS join_customer_id, 
      id, CAST(id AS STRING) AS join_id, 
      adoption_since, 
      type, 
      mes_en_curso, 
      month, DATE_TRUNC(DATE(month), MONTH) AS join_month, 
      acquisition_since, 
      adoption_until, 
      acquisition_until
    FROM `peya-peru.automated_tables_reports.first_dmart_order_date_users`
  ),
  src_customer_orders_sku_level AS (
    SELECT 
      order_date, 
      DATE_TRUNC(DATE(order_date), MONTH) AS join_order_month,
      customer_id, CAST(customer_id AS STRING) AS join_customer_id, 
      order_id, CAST(order_id AS STRING) AS join_order_id, 
      fulfilled_quantity, 
      master_category_parent_english, 
      total_amount_net_with_discount_lc, 
      store_name, 
      vendor_id, CAST(vendor_id AS STRING) AS join_vendor_id, 
      CAST(order_timestamp AS DATETIME) AS order_timestamp, 
      sku_id, CAST(sku_id AS STRING) AS join_sku_id, 
      ordered_quantity, 
      total_amount_sold_net_lc, 
      total_cogs_sold_net_lc, 
      pcm_discount_amount_net_lc, 
      pcm_discount_subtype, 
      target_audience, 
      campaign_name, 
      campaign_purpose,
      CASE 
        WHEN (
          LOWER(target_audience) IN ('segment_user', 'new_user') 
          AND LOWER(campaign_name) NOT LIKE '%%test ild%%'
          AND LOWER(campaign_name) NOT LIKE '%%_category_%%'
          AND LOWER(campaign_purpose) NOT IN ('expiring Soon', 'overstock', 'delisting')
        ) THEN pcm_discount_amount_net_lc ELSE 0 
      END AS ild_amount
    FROM `peya-datamarts-pro.dm_dmarts.customer_orders_sku_level`
    WHERE country_code = 'pe' 
      AND state = 'CONFIRMED'
      AND DATE(order_date) >= current_month
  ),
  src_monthly_user_info AS (
    SELECT 
      user_id, CAST(user_id AS STRING) AS join_user_id, 
      mes, DATE_TRUNC(DATE(mes), MONTH) AS join_month, 
      present_month_status_user, 
      past_month_status_user, 
      dm_past_month_orders, 
      f_present_month_orders, 
      ls_present_month_orders, 
      c_present_month_orders, 
      f_past_month_orders, 
      ls_past_month_orders, 
      c_past_month_orders
    FROM `peya-peru.automated_tables_reports.monthly_user_info`
    WHERE country_name = 'Perú'
  ),
  src_skus_pim_dmart AS (
    SELECT 
      sku, CAST(sku AS STRING) AS join_sku, 
      piece_barcode, level_1, level_2, level_3, level_4, country_code
    FROM `peya-food-and-groceries.automated_tables_reports.skus_PIM_Dmart`
  ),
  src_pim_level_0_bis AS (
    SELECT level_1, level_0
    FROM `peya-argentina.automated_tables_reports.PIM_Level_0_Bis`
  ),
  src_fact_payments_transaction AS (
    SELECT 
      order_id, CAST(order_id AS STRING) AS join_order_id, 
      issuer, card_operation_type, provider, 
      restaurant_id, CAST(restaurant_id AS STRING) AS join_restaurant_id
    FROM `peya-bi-tools-pro.il_payments.fact_payments_transaction`
    WHERE country_id = 7 AND payment_state = 'ACCEPTED' AND DATE(date_created) >= current_month
  ),
  src_dmarts_vendor_profiles AS (
    SELECT codigo, CAST(codigo AS STRING) AS join_codigo FROM `peya-peru.user_christian_la.dmarts_vendor_profiles`
  ),
  src_fact_orders AS (
    SELECT 
      order_id, CAST(order_id AS STRING) AS join_order_id, 
      user.id AS user_id, CAST(user.id AS STRING) AS join_user_id, 
      customer_id AS customer_real_id, CAST(customer_id AS STRING) AS join_customer_real_id, 
      promisedDeliveryTime.maxMinutes, 
      promisedDeliveryTime.minMinutes, 
      delivery_fee_revenue, 
      shipping_amount_no_discount / 1.18 AS shipping_amount_no_discount, 
      shipping_amount_no_discount AS shipping_amount_visualized, 
      shipping_amount, 
      distance_meters AS distance, 
      is_user_plus AS plus_order, 
      total_amount, 
      has_bins_discount, 
      is_user_plus
    FROM `peya-bi-tools-pro.il_core.fact_orders`
    WHERE DATE(registered_date) >= current_month
  ),
  src_fact_talon_coupons AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, coupon_used_amount
    FROM `peya-bi-tools-pro.il_growth.fact_talon_coupons`
  ),
  src_agg_user_lifecycle AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, health_status, intermittency_type, funnel, lifecycle_stage
    FROM `peya-bi-tools-pro.il_growth.agg_user_lifecycle`
  ),
  src_user_income AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, age AS u_age, age_group, gender, gender_merged, dh_age_prediction, dh_gender_prediction, cell_segment AS u_cell_segment, income AS u_income, segment, user_demographic_group
    FROM `peya-bi-tools-pro.il_growth.user_income`
  ),
  src_peru_clusters AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, mes, DATE_TRUNC(DATE(mes), MONTH) AS join_month, n_cluster
    FROM `peya-peru.automated_tables_reports.peru_clusters`
  ),
  src_dim_coupon_crm_attributes AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, type, segment, nivel, funnel, purpose, campaign, campaign_id, crm_vertical, crm_lifecycle, coupon_origin
    FROM `peya-peru.automated_tables_reports.dim_coupon_crm_attributes`
  ),
  src_dps_order_info AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, dropoff_distance_manhattan_m, order_delay_mins, scheme_id, dps_minimum_order_value_local, dps_delivery_fee_local, dps_basket_value_fee_local, is_df_discount_basket_value_deal
    FROM `peya-peru.automated_tables_reports.dps_order_info`
    WHERE DATE(registered_date) >= current_month
  ),
  src_df090_dma_discounts_bines AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, descuento, aporte_peya, aporte_banco, aporte_partner, inv_peya_en_lcy, inv_bancos_en_lcy, inv_partner_en_lcy
    FROM `peya-peru.user_christian_la.DF090_DMA_DISCOUNTS_BINES`
  ),
  src_dmart_purchase_missions AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, month, DATE_TRUNC(DATE(month), MONTH) AS join_month, category
    FROM `peya-peru.user_christian_la.dmart_purchase_missions`
  ),
  src_dmart_behavioural_clustering AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, month, DATE_TRUNC(DATE(month), MONTH) AS join_month, dmart_cluster, final_dm_cluster
    FROM `peya-peru.user_christian_la.dmart_behavioural_clustering`
  ),
  src_dmarts_customer_compliant AS (
    SELECT order_number, CAST(order_number AS STRING) AS join_order_id, customer_id, CAST(customer_id AS STRING) AS join_customer_id, ccr1, ccr2, ccr3, user_fraud, user_trust_segment, case_origin, amount, euros, case_number
    FROM `peya-delivery-and-support.automated_tables_reports.dmarts_customer_compliant`
    WHERE country = 'Perú' AND DATE(order_date) >= current_month
  ),
  src_orders_pe AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, estimated_prep_time, updated_prep_time, to_customer_time, timing_promised_delivery_time, actual_delivery_time, is_order_late_10, is_vendor_late, count_orders_inaccuracy, is_pre_order, total_orders_vl, dropoff_distance_manhattan, is_stacked, hold_back_time
    FROM `peya-peru.automated_tables_reports.OrdersPE`
    WHERE DATE(created_date) >= current_month
  ),
  src_dmart_growth_tracker AS (
    SELECT user_id, CAST(user_id AS STRING) AS join_user_id, month, DATE_TRUNC(DATE(month), MONTH) AS join_month, bop_level_0, bop_level_1, bop_level_2, benefit_segment, month_dechurned, platform_current_frequency, sundays_boolean, sundays_boolean_last_month, activated_by, last_month_activated_by, user_dmart_frequency_interval, dmart_category_range, dmart_lifetime_stage, plus_dmarts_lifecycle, user_range_retention_tag
    FROM `peya-peru.automated_tables_reports.dmart_growth_tracker`
  ),
  src_fact_groceries_shopping_missions AS (
    SELECT order_id, CAST(order_id AS STRING) AS join_order_id, mission_type
    FROM `peya-bi-tools-pro.il_qcommerce.fact_groceries_shopping_missions`
    WHERE DATE(registered_date) >= current_month
  ),

  -- =================================================================================
  -- 2. BLOQUES DE PREPARACIÓN OPTIMIZADOS
  -- =================================================================================
  
  user_global_dates AS (
    SELECT DISTINCT join_id AS join_user_id, adoption_since, acquisition_since, adoption_until, acquisition_until 
    FROM src_first_dmart_order_date_users
  ),
  
  date_grid AS (
    SELECT DISTINCT 
      join_user_id, 
      month_iter AS join_month
    FROM user_global_dates
    CROSS JOIN UNNEST(GENERATE_DATE_ARRAY(
      DATE_TRUNC(DATE(adoption_since), MONTH), 
      DATE_TRUNC(CURRENT_DATE(), MONTH), 
      INTERVAL 1 MONTH
    )) AS month_iter
  ),

  user_monthly_status AS (
    SELECT join_id AS join_user_id, join_month, type, mes_en_curso
    FROM src_first_dmart_order_date_users
  ),

  user_monthly_orders AS (
    SELECT
      join_customer_id AS join_user_id,
      join_order_month AS join_month,
      COUNT(DISTINCT join_order_id) AS dm_current_frequency,
      SAFE_DIVIDE(SUM(fulfilled_quantity), COUNT(DISTINCT join_order_id)) AS basket_size,
      COUNT(DISTINCT master_category_parent_english) AS categories,
      SAFE_DIVIDE(SUM(total_amount_net_with_discount_lc), COUNT(DISTINCT join_order_id)) AS afv
    FROM src_customer_orders_sku_level
    GROUP BY 1, 2
  ),

  prep_skus_pim AS (
    SELECT k.join_sku, k.piece_barcode, p.level_0, k.level_1, k.level_2, k.level_3, k.level_4, k.country_code 
    FROM src_skus_pim_dmart k
    LEFT JOIN src_pim_level_0_bis p ON p.level_1 = k.level_1
    QUALIFY ROW_NUMBER() OVER(PARTITION BY k.join_sku ORDER BY k.piece_barcode DESC) = 1
  ),

  prep_payments AS (
    SELECT fo.join_order_id, fo.issuer AS bank, fo.card_operation_type AS operation_type, fo.provider AS payment_name
    FROM src_fact_payments_transaction fo
    LEFT JOIN src_dmarts_vendor_profiles v ON v.join_codigo = fo.join_restaurant_id
    QUALIFY ROW_NUMBER() OVER(PARTITION BY fo.join_order_id ORDER BY fo.issuer DESC) = 1
  ),

  prep_dmart_purchase_missions AS (
    SELECT *, LAG(category) OVER (PARTITION BY join_user_id ORDER BY join_month) AS dmart_pm_shopping_mission_prior_month
    FROM src_dmart_purchase_missions 
  ),

  prep_dmart_behavioural_clustering AS (
    SELECT *, LAG(dmart_cluster) OVER (PARTITION BY join_user_id ORDER BY join_month) AS dmart_cluster_prior_month
    FROM src_dmart_behavioural_clustering
  ),

  prep_dmarts_customer_compliant AS (
    SELECT join_order_id, ccr1, ccr2, ccr3, user_fraud, user_trust_segment, case_origin, SUM(amount) AS sum_amount, SUM(euros) AS sum_euros, COUNT(DISTINCT(case_number)) AS cases
    FROM src_dmarts_customer_compliant
    GROUP BY 1, 2, 3, 4, 5, 6, 7
  ),

  -- =================================================================================
  -- 3. MODELADO DE DATOS (USUARIOS Y ÓRDENES)
  -- =================================================================================
  
  dmart_data AS (
    SELECT
      dg.join_user_id,
      IFNULL(ums.type, 'Churned') AS dmart_growth_status,
      ums.type,
      ums.mes_en_curso,
      ugd.adoption_since,
      ugd.acquisition_since,
      ugd.adoption_until,
      ugd.acquisition_until,
      dg.join_month,
      IFNULL(umo.dm_current_frequency, 0) AS dm_current_frequency,
      umo.basket_size,
      umo.categories,
      umo.afv
    FROM date_grid dg
    LEFT JOIN user_global_dates ugd ON dg.join_user_id = ugd.join_user_id
    LEFT JOIN user_monthly_status ums ON dg.join_user_id = ums.join_user_id AND dg.join_month = ums.join_month
    LEFT JOIN user_monthly_orders umo ON dg.join_user_id = umo.join_user_id AND dg.join_month = umo.join_month
  ),

  user_data AS (
    SELECT
      dd.*,
      m.present_month_status_user AS platform_status,
      m.past_month_status_user AS platform_prior_status,
      LAG(dd.dmart_growth_status) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) AS dmart_growth_status_past_month,
      LAG(dd.mes_en_curso) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) AS previous_mes_en_curso,

      CASE
        WHEN dd.dmart_growth_status IN ('Adoption', 'Churned', 'Reactivated') THEN LOWER(dd.dmart_growth_status)
        WHEN dd.dm_current_frequency > LAG(dd.dm_current_frequency) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) AND dd.afv > LAG(dd.afv) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) THEN 'increased_afv_frec'  
        WHEN dd.afv > LAG(dd.afv) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) THEN 'increased_afv'  
        WHEN dd.afv < LAG(dd.afv) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) THEN 'decreased_afv' 
        ELSE 'steady performance'
      END AS dmart_afv_performance,

      CASE
        WHEN dd.dmart_growth_status IN ('Adoption', 'Churned', 'Reactivated') THEN LOWER(dd.dmart_growth_status)
        WHEN dd.dm_current_frequency > LAG(dd.dm_current_frequency) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) THEN 'increased_frec'
        WHEN dd.dm_current_frequency < LAG(dd.dm_current_frequency) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month) THEN 'decreased_frec'
        ELSE 'steady performance'
      END AS dmart_frec_performance,

      SUM(m.dm_past_month_orders) OVER(PARTITION BY dd.join_user_id, dd.join_month) AS dm_prior_frequency,
      SUM(IFNULL(m.f_present_month_orders,0) + IFNULL(m.ls_present_month_orders,0) + IFNULL(m.c_present_month_orders,0)) OVER(PARTITION BY dd.join_user_id, dd.join_month) AS platform_current_frequency,
      SUM(IFNULL(m.f_past_month_orders,0) + IFNULL(m.ls_past_month_orders,0) + IFNULL(m.c_past_month_orders,0)) OVER(PARTITION BY dd.join_user_id, dd.join_month) AS platform_prior_frequency,
      SUM(IFNULL(m.ls_present_month_orders,0) + IFNULL(m.c_present_month_orders,0)) OVER(PARTITION BY dd.join_user_id, dd.join_month) AS ls_current_frequency,
      SUM(IFNULL(m.ls_past_month_orders,0) + IFNULL(m.c_past_month_orders,0)) OVER(PARTITION BY dd.join_user_id, dd.join_month) AS ls_prior_frequency,

      MAX(CASE WHEN dd.dm_current_frequency > 0 THEN dd.join_month END) OVER (PARTITION BY dd.join_user_id ORDER BY dd.join_month ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS last_month_active
    FROM dmart_data dd
    LEFT JOIN src_monthly_user_info m ON dd.join_user_id = m.join_user_id AND dd.join_month = m.join_month
  ),

  united_users AS (
    SELECT
      u.*,
      CASE WHEN dmart_growth_status_past_month = 'Reactivated' AND dmart_growth_status = 'Recurring Return' THEN 'Reorder' ELSE dmart_growth_status END AS dmart_growth_status_fixed,
      CASE
        WHEN dmart_growth_status <> 'Churned' THEN dmart_growth_status
        WHEN dmart_growth_status_past_month IN ('Adoption', 'M1 Return') AND dmart_growth_status = 'Churned' THEN 'dmart_early_churn'
        WHEN dmart_growth_status = 'Churned' AND dmart_growth_status_past_month = 'Churned' THEN 'dmart_recurring_churn'
        WHEN dmart_growth_status = 'Churned' AND dmart_growth_status_past_month = 'Reactivated' THEN 'dmart_strong_churn'
        ELSE 'regular churn' 
      END AS dmart_churn_type,
      CASE
        WHEN platform_status = 'Churned' THEN 'churned'
        WHEN dmart_growth_status = 'Reactivated' THEN 'reactivated'
        WHEN platform_current_frequency > platform_prior_frequency THEN 'increased_frec' 
        WHEN platform_current_frequency < platform_prior_frequency THEN 'decreased_frec'
        ELSE 'steady performance'
      END AS platform_performance,
      IFNULL(DATE_DIFF(join_month, last_month_active, MONTH), 0) AS activation_period
    FROM user_data u
  ),

  prep_united_users AS (
    SELECT
      *,
      LAG(dmart_churn_type) OVER (PARTITION BY join_user_id ORDER BY join_month) AS dmart_churn_type_prior_month
    FROM united_users
  ),

  customer_orders AS (
    SELECT
      o.store_name, o.vendor_id, o.order_date, o.join_order_month, o.order_timestamp, o.customer_id, o.join_customer_id, o.order_id, o.join_order_id,
      COUNT(DISTINCT e.level_2) AS categories,
      SUM(o.ordered_quantity) AS ordered,
      SUM(o.fulfilled_quantity) AS fulfilled,
      SUM(o.total_amount_sold_net_lc) AS venta,
      SUM(o.total_amount_net_with_discount_lc) AS venta_neta,
      SUM(o.total_cogs_sold_net_lc) AS cost,
      SUM(o.pcm_discount_amount_net_lc) AS discount,
      SUM(o.total_amount_net_with_discount_lc) - SUM(o.total_cogs_sold_net_lc) AS front_margin,
      SUM(o.total_amount_sold_net_lc) - SUM(o.total_cogs_sold_net_lc) AS theoric_margin,
      SAFE_DIVIDE(SUM(o.pcm_discount_amount_net_lc), SUM(o.total_amount_sold_net_lc)) AS discount_rate,

      CASE
        WHEN SUM(o.fulfilled_quantity) > 19 THEN 'Outliers'
        WHEN SUM(o.fulfilled_quantity) >= 15 AND SUM(o.fulfilled_quantity) <= 19 THEN 'Supermarket Family Size'
        WHEN SUM(o.fulfilled_quantity) >= 7 AND SUM(o.fulfilled_quantity) <= 14 THEN 'Supermarket Orders'
        WHEN SUM(o.fulfilled_quantity) BETWEEN 5 AND 6 THEN 'Healthy Convenience'
        WHEN SUM(o.fulfilled_quantity) BETWEEN 3 AND 4 THEN 'Convenience Orders'
        WHEN SUM(o.fulfilled_quantity) BETWEEN 1 AND 2 THEN 'Impulse Orders'
        ELSE 'Invalid Basket Size'
      END AS basket_segment,

      CASE
        WHEN SUM(o.total_amount_sold_net_lc) >= 99 THEN '[99,+]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 90 THEN '[90,99]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 80 THEN '[80,89]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 70 THEN '[70,79]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 60 THEN '[60,69]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 50 THEN '[50,59]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 40 THEN '[40,49]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 30 THEN '[30,39]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 20 THEN '[20,29]'
        WHEN SUM(o.total_amount_sold_net_lc) >= 10 THEN '[10,19]'
        ELSE '[00,09]'
      END AS afv_segment,

      MAX(CASE WHEN e.level_0 IN ('Fresh', 'Ultra Fresh') AND o.fulfilled_quantity > 0 THEN 1 ELSE 0 END) AS fresh_order,
      MAX(CASE WHEN e.level_0 = 'Ultra Fresh' AND o.fulfilled_quantity > 0 THEN 1 ELSE 0 END) AS ultra_fresh_order,
      MAX(CASE WHEN o.pcm_discount_amount_net_lc > 0 THEN 1 ELSE 0 END) AS discount_order,
      CASE WHEN SAFE_DIVIDE(SUM(o.pcm_discount_amount_net_lc), SUM(o.total_amount_sold_net_lc)) >= 0.25 THEN 1 ELSE 0 END AS discount_incentivized,
      MAX(CASE WHEN o.pcm_discount_subtype = 'multi-buy' AND o.fulfilled_quantity > 0 THEN 1 ELSE 0 END) AS multibuy_order,
      MAX(CASE WHEN o.target_audience = 'SUBSCRIBED_USER' AND o.pcm_discount_amount_net_lc > 0 THEN 1 ELSE 0 END) AS plus_item_level,
      MAX(CASE WHEN o.ild_amount > 0 THEN 1 ELSE 0 END) AS is_ild

    FROM src_customer_orders_sku_level o
    LEFT JOIN prep_skus_pim e ON o.join_sku_id = e.join_sku
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
  ),

  -- =================================================================================
  -- 4. JOIN PRINCIPAL Y REEMPLAZO DE CTES FINALES POR WINDOW FUNCTIONS (1 Solo Pase)
  -- =================================================================================
  
  peru_dmarts_orders AS (
    SELECT
      s.order_date,
      s.order_timestamp,
      EXTRACT(HOUR FROM s.order_timestamp) AS hour,
      DATE_TRUNC(s.order_date, YEAR) AS year,
      DATE_TRUNC(s.order_date, MONTH) AS month,
      FORMAT_DATE('%U', DATE_TRUNC(s.order_date, WEEK(MONDAY))) AS week_of_year,
      s.store_name, s.vendor_id, s.customer_id AS sku_level_customer_id,
      o1.user_id AS customer_id, o1.customer_real_id AS customer_adverted_id,
      
      CASE 
        WHEN s.order_date < '2022-07-01' THEN 'Growth Stage'
        WHEN s.order_date BETWEEN '2022-07-01' AND '2022-12-31' THEN 'Improving the Basics' 
        ELSE 'Growth & Profitability' 
      END AS business_stage,

      CASE WHEN s.order_date BETWEEN d.adoption_since AND d.adoption_until THEN 'adoption' ELSE 'active' END AS adoption_type,
      CASE WHEN s.order_date BETWEEN d.acquisition_since AND d.acquisition_until THEN 'acquisition' ELSE 'active' END AS acquisition_type,

      d.adoption_since AS cohort_date, d.mes_en_curso, d.type AS type_user,
      be.final_dm_cluster AS crm_pe_dm_cluster, be.dmart_cluster AS crm_pe_dmart_cluster, be.dmart_cluster_prior_month AS crm_pe_dmart_cluster_prior_month,
      d.platform_performance, d.platform_status, d.platform_prior_status, d.dmart_churn_type_prior_month, d.dmart_frec_performance, d.dmart_afv_performance, d.dmart_growth_status_past_month, d.dmart_growth_status, d.dmart_growth_status_fixed AS dmart_growth_stage, d.last_month_active AS dmart_last_month_active, d.activation_period AS dmart_activation_period,
      pm.category AS dmart_shopping_mission, pm.dmart_pm_shopping_mission_prior_month,
      
      comp.ccr1 AS comp_ccr1, comp.ccr2 AS comp_ccr2, comp.ccr3 AS comp_ccr3, comp.user_fraud AS comp_user_fraud, comp.case_origin AS comp_case_origin, comp.user_trust_segment,
      
      db.descuento AS d_bin_campaign, db.aporte_peya AS d_aporte_peya, db.aporte_banco AS d_aporte_banco, db.aporte_partner AS d_aporte_partner, db.inv_peya_en_lcy AS d_inv_peya, db.inv_bancos_en_lcy AS d_inv_bancos, db.inv_partner_en_lcy AS d_inv_partner,
      CASE WHEN db.descuento = 'Plus en PedidosYa Market' THEN 1 ELSE 0 END AS sunday_plus,
      CASE WHEN db.descuento LIKE '%Fija%' THEN 1 ELSE 0 END AS fija_plus,
      CASE WHEN db.descuento LIKE '%Plus%' THEN 1 ELSE 0 END AS plus_benefit_orders,

      h.health_status, h.intermittency_type AS h_int_type, h.funnel AS h_funnel, h.lifecycle_stage AS h_lifecycle_stage,
      
      u.u_age, u.age_group, u.gender, MAX(u.gender_merged) OVER(PARTITION BY s.join_customer_id) AS gender_merged, MAX(u.dh_age_prediction) OVER(PARTITION BY s.join_customer_id) AS dh_age_prediction, MAX(u.dh_gender_prediction) OVER(PARTITION BY s.join_customer_id) AS dh_gender_prediction, u.u_cell_segment, u.u_income, MAX(u.segment) OVER(PARTITION BY s.join_customer_id) AS u_segmemnt, MAX(u.user_demographic_group) OVER(PARTITION BY s.join_customer_id) AS u_user_demographic_group, 

      gt.bop_level_0, gt.bop_level_1, gt.bop_level_2, gt.benefit_segment, gt.platform_current_frequency, gt.month_dechurned, gt.sundays_boolean, gt.sundays_boolean_last_month, gt.activated_by, gt.last_month_activated_by, NULL AS wine_user, gt.dmart_category_range, gt.user_dmart_frequency_interval, gt.dmart_lifetime_stage, gt.plus_dmarts_lifecycle, gt.user_range_retention_tag,
      FALSE AS rmo_high_mov, FALSE AS rmo_qc_dmart,

      s.order_id, pay.bank, pay.operation_type, pay.payment_name,
      
      fo.estimated_prep_time, fo.updated_prep_time, fo.to_customer_time, fo.timing_promised_delivery_time, fo.actual_delivery_time, fo.is_order_late_10, fo.is_vendor_late, fo.count_orders_inaccuracy AS is_inaccuracy, fo.is_pre_order,
      CASE WHEN fo.total_orders_vl = 1 AND fo.is_pre_order = 0 THEN TRUE ELSE FALSE END AS has_delivery_time,
      CASE WHEN fo.actual_delivery_time > fo.timing_promised_delivery_time THEN 1 ELSE 0 END AS late_order,
      fo.dropoff_distance_manhattan AS fo_dropoff_distance_manhattan,

      o1.delivery_fee_revenue, o1.total_amount, o1.shipping_amount, o1.shipping_amount_no_discount, o1.shipping_amount_visualized, o1.maxMinutes, o1.minMinutes, o1.is_user_plus,

      CASE WHEN vouchers.coupon_used_amount >= 0 THEN v.type WHEN o1.plus_order > 0 THEN 'Plus' ELSE 'Organic' END AS coupon_type,
      v.segment AS coupon_segment, v.nivel AS coupon_nivel, v.funnel AS coupon_funnel, v.purpose AS coupon_purpose, v.campaign AS coupon_campaign, v.campaign_id AS coupon_campaign_id, v.crm_vertical, v.crm_lifecycle, v.coupon_origin,
      CASE WHEN o1.plus_order > 0 THEN 'Plus' WHEN vouchers.coupon_used_amount >= 0 THEN v.type ELSE 'Organic' END AS coupon_type_barter,
      cluster.n_cluster AS crm_pe_cluster, 

      CASE 
        WHEN o1.has_bins_discount = 1 THEN 'Bin'
        WHEN o1.is_user_plus > 0 THEN 'Plus'
        WHEN v.crm_vertical = 'DMART' THEN 'Dmart RMO'
        WHEN vouchers.coupon_used_amount >= 0 AND v.type IN ('RMO', 'RMA', 'RAF') THEN v.type
        WHEN vouchers.coupon_used_amount >= 0 THEN 'Other Vouchers'
        ELSE 'Organic' 
      END AS order_source,

      CASE 
        WHEN o1.has_bins_discount = 1 THEN '3-Bin'
        WHEN o1.is_user_plus > 0 THEN '2.Plus'
        WHEN v.crm_vertical = 'DMART' THEN '4.Dmart RMO'
        WHEN vouchers.coupon_used_amount >= 0 THEN '5.Other Vouchers'
        ELSE '1.Organic' 
      END AS order_source_level_one,

      dps.dropoff_distance_manhattan_m AS dps_dropoff_distance_manhattan_meters, dps.order_delay_mins AS dps_order_delay_mins, dps.scheme_id AS dps_scheme_id, dps.dps_minimum_order_value_local AS dps_mov_lc, dps.dps_delivery_fee_local AS dps_df_applied, dps.dps_basket_value_fee_local AS dps_basket_value, dps.is_df_discount_basket_value_deal AS flag_basket_value,

      shop.mission_type,
      s.basket_segment, s.fresh_order, s.ultra_fresh_order, s.discount_order, s.discount_incentivized, s.multibuy_order, s.venta_neta AS gfv, s.venta AS gmv, s.cost, s.theoric_margin, s.front_margin, s.discount AS discounts, s.fulfilled AS basket_sz, s.afv_segment, s.categories,
      fo.is_stacked AS flag_stacked, 
      CASE WHEN o1.plus_order > 0 AND s.plus_item_level > 0 THEN 2 WHEN o1.plus_order > 0 AND s.plus_item_level = 0 THEN 1 ELSE 0 END AS flag_plus,
      s.is_ild,
      CASE WHEN o1.plus_order > 0 THEN 'PeYa Plus Order' ELSE 'Regular Order' END AS peyaplus,
      vouchers.coupon_used_amount / 1.18 AS voucher_amount_net,
      CASE WHEN vouchers.coupon_used_amount >= 0 THEN 1 ELSE 0 END AS flag_vc,
      CASE WHEN o1.delivery_fee_revenue > 0.5 THEN 'Inc. Delivery Fee' ELSE 'No Inc. DF' END AS flag_df,
      CASE WHEN vouchers.coupon_used_amount >= 0 THEN 'Voucher' ELSE 'No Voucher' END AS flag_voucher,
      CASE WHEN o1.delivery_fee_revenue > 0.5 THEN 0 ELSE 1 END AS flag_delivery_free,
      
      CASE 
        WHEN vouchers.coupon_used_amount >= 0 THEN CASE WHEN o1.delivery_fee_revenue <= 0.5 THEN 'Voucher & Free Delivery' ELSE 'Voucher' END
        ELSE CASE WHEN o1.delivery_fee_revenue <= 0.5 THEN 'Free Delivery' ELSE 'Organic Order' END
      END AS order_sub_nature,
      
      ROW_NUMBER() OVER(PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS order_number,
      ROW_NUMBER() OVER(PARTITION BY s.join_customer_id, s.join_order_month ORDER BY s.order_timestamp ASC) AS order_num_month,
      fo.hold_back_time,

      -- ==================================================================
      -- Reemplazando los 5 CTEs Finales con Window Functions In-Line
      -- ==================================================================
      
      -- adoption_type CTE logic
      FIRST_VALUE(CASE WHEN s.order_date >= d.acquisition_since AND s.order_date <= d.acquisition_until THEN 'acquisition' ELSE 'adoption' END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_origin,
      FIRST_VALUE(CASE WHEN s.is_ild = 1 THEN 'ILD Trial' WHEN (vouchers.coupon_used_amount >= 0) THEN 'Voucher Trial' WHEN (o1.plus_order > 0 AND s.plus_item_level > 0) THEN 'ILD Plus' WHEN (o1.plus_order > 0 AND s.plus_item_level = 0) THEN 'Plus Trial' ELSE 'Organic' END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_class,
      FIRST_VALUE(CASE WHEN (vouchers.coupon_used_amount >= 0) THEN 'Voucher Incentivized' ELSE 'Organic' END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_class_test,
      FIRST_VALUE(CASE WHEN (vouchers.coupon_used_amount >= 0) THEN v.campaign END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_coupon_used,
      FIRST_VALUE(CASE WHEN (vouchers.coupon_used_amount >= 0) THEN v.funnel END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_funnel_used,
      FIRST_VALUE(CASE WHEN (vouchers.coupon_used_amount >= 0) THEN v.crm_vertical END) OVER (PARTITION BY s.join_customer_id ORDER BY s.order_timestamp ASC) AS adoption_vertical_attributed,

      -- week_start_day CTE logic
      MIN(MOD(EXTRACT(DAYOFWEEK FROM s.order_date) + 5, 7) + 1) OVER (PARTITION BY s.join_customer_id, FORMAT_DATE('%U', DATE_TRUNC(s.order_date, WEEK(MONDAY)))) AS wsd_start_day,

      -- activation_source CTE logic
      FIRST_VALUE(CASE WHEN vouchers.coupon_used_amount >= 0 THEN 'CRM' WHEN (vouchers.coupon_used_amount IS NULL OR vouchers.coupon_used_amount < 0) AND (o1.plus_order > 0 AND s.plus_item_level = 0) THEN 'Plus' WHEN (vouchers.coupon_used_amount IS NULL OR vouchers.coupon_used_amount < 0) AND (o1.plus_order > 0 AND s.plus_item_level > 0) THEN 'Plus Item Level' ELSE 'Organic' END) OVER (PARTITION BY s.join_customer_id, s.join_order_month ORDER BY s.order_timestamp ASC) AS month_activation_source,
      FIRST_VALUE(CASE WHEN vouchers.coupon_used_amount >= 0 THEN v.crm_vertical WHEN (vouchers.coupon_used_amount IS NULL OR vouchers.coupon_used_amount < 0) AND o1.plus_order > 0 THEN 'Plus' ELSE 'Organic' END) OVER (PARTITION BY s.join_customer_id, s.join_order_month ORDER BY s.order_timestamp ASC) AS month_activation_funnel_source,

      -- monthly_user CTE logic preparations (Pre-calculating booleans for the month partition)
      MAX(CASE WHEN shop.mission_type = 'Stock Up' THEN 1 ELSE 0 END) OVER (PARTITION BY s.join_customer_id, s.join_order_month) AS has_stock_up_mission,
      MAX(CASE WHEN shop.mission_type = 'Fill In' THEN 1 ELSE 0 END) OVER (PARTITION BY s.join_customer_id, s.join_order_month) AS has_fill_in_mission,
      MAX(CASE WHEN (CASE WHEN s.fulfilled BETWEEN 1 AND 5 OR s.categories BETWEEN 1 AND 2 THEN 'Instant Need' WHEN s.fulfilled BETWEEN 6 AND 15 AND s.categories BETWEEN 3 AND 4 THEN 'Fill In' WHEN s.fulfilled > 15 AND s.categories >= 5 THEN 'Stock Up' WHEN s.fulfilled > 5 THEN 'Fill In' END) = 'Stock Up' THEN 1 ELSE 0 END) OVER (PARTITION BY s.join_customer_id, s.join_order_month) AS user_has_stock_up_v2,
      MAX(CASE WHEN (CASE WHEN s.fulfilled BETWEEN 1 AND 5 OR s.categories BETWEEN 1 AND 2 THEN 'Instant Need' WHEN s.fulfilled BETWEEN 6 AND 15 AND s.categories BETWEEN 3 AND 4 THEN 'Fill In' WHEN s.fulfilled > 15 AND s.categories >= 5 THEN 'Stock Up' WHEN s.fulfilled > 5 THEN 'Fill In' END) = 'Fill In' THEN 1 ELSE 0 END) OVER (PARTITION BY s.join_customer_id, s.join_order_month) AS user_has_fill_in_v2
      
    FROM customer_orders s
    LEFT JOIN src_fact_orders o1 ON s.join_order_id = o1.join_order_id
    LEFT JOIN src_fact_talon_coupons vouchers ON s.join_order_id = vouchers.join_order_id
    LEFT JOIN src_agg_user_lifecycle h ON s.join_customer_id = h.join_user_id
    LEFT JOIN src_user_income u ON s.join_customer_id = u.join_user_id
    LEFT JOIN src_peru_clusters cluster ON s.join_customer_id = cluster.join_user_id AND s.join_order_month = cluster.join_month
    LEFT JOIN prep_payments pay ON s.join_order_id = pay.join_order_id
    LEFT JOIN src_dim_coupon_crm_attributes v ON s.join_order_id = v.join_order_id
    LEFT JOIN src_dps_order_info dps ON s.join_order_id = dps.join_order_id
    LEFT JOIN prep_united_users d ON o1.join_user_id = d.join_user_id AND s.join_order_month = d.join_month
    LEFT JOIN src_df090_dma_discounts_bines db ON s.join_order_id = db.join_order_id
    LEFT JOIN prep_dmart_purchase_missions pm ON s.join_customer_id = pm.join_user_id AND s.join_order_month = pm.join_month
    LEFT JOIN prep_dmart_behavioural_clustering be ON s.join_customer_id = be.join_user_id AND s.join_order_month = be.join_month
    LEFT JOIN prep_dmarts_customer_compliant comp ON s.join_order_id = comp.join_order_id
    LEFT JOIN src_orders_pe fo ON s.join_order_id = fo.join_order_id
    LEFT JOIN src_dmart_growth_tracker gt ON s.join_customer_id = gt.join_user_id AND s.join_order_month = gt.join_month
    LEFT JOIN src_fact_groceries_shopping_missions shop ON s.join_order_id = shop.join_order_id
  )

SELECT
  k.* EXCEPT(
    adoption_origin,
    adoption_class,
    adoption_class_test,
    adoption_coupon_used,
    adoption_funnel_used,
    adoption_vertical_attributed,
    wsd_start_day,
    month_activation_source,
    month_activation_funnel_source,
    has_stock_up_mission,
    has_fill_in_mission,
    user_has_stock_up_v2,
    user_has_fill_in_v2
  ),
  
  -- ORDENAMIENTO ESTRICTO PARA EVITAR ERRORES DE INSERT:
  CASE WHEN k.comp_ccr1 IS NOT NULL THEN 1 ELSE 0 END AS flag_inaccuracy,
  CASE WHEN (k.comp_ccr1 IS NOT NULL AND k.late_order = 1) THEN 1 ELSE 0 END AS inaccuracy_late,
  k.month_activation_source,
  k.month_activation_funnel_source,
  k.adoption_origin,
  k.adoption_class,
  k.adoption_class_test,
  k.adoption_coupon_used,
  k.adoption_funnel_used,
  k.adoption_vertical_attributed,
  CONCAT('W', CAST(k.week_of_year AS STRING), '-', CAST(k.wsd_start_day AS STRING)) AS wsd_week_and_day,
  k.wsd_start_day,
  
  CASE WHEN k.basket_sz BETWEEN 1 AND 5 OR k.categories BETWEEN 1 AND 2 THEN 'Instant Need' WHEN k.basket_sz BETWEEN 6 AND 15 AND k.categories BETWEEN 3 AND 4 THEN 'Fill In' WHEN k.basket_sz > 15 AND k.categories >= 5 THEN 'Stock Up' WHEN k.basket_sz > 5 THEN 'Fill In' ELSE NULL END AS dh_shopping_mission,
  
  CASE WHEN k.actual_delivery_time >= 0 THEN CASE WHEN k.actual_delivery_time <= 10 THEN '[0,10]' WHEN k.actual_delivery_time <= 20 THEN '[10,20]' WHEN k.actual_delivery_time <= 30 THEN '[20,30]' WHEN k.actual_delivery_time <= 40 THEN '[30,40]' WHEN k.actual_delivery_time <= 50 THEN '[40,50]' ELSE '[50,+]' END END AS timings_actual_dt_interval,
  CASE WHEN k.timing_promised_delivery_time >= 0 THEN CASE WHEN k.timing_promised_delivery_time <= 10 THEN '[0,10]' WHEN k.timing_promised_delivery_time <= 20 THEN '[10,20]' WHEN k.timing_promised_delivery_time <= 30 THEN '[20,30]' WHEN k.timing_promised_delivery_time <= 40 THEN '[30,40]' WHEN k.timing_promised_delivery_time <= 50 THEN '[40,50]' ELSE '[50,+]' END END AS timings_potential_dt_interval,

  CASE WHEN k.has_stock_up_mission = 1 THEN 'Stock Up' WHEN k.has_fill_in_mission = 1 THEN 'Fill In' ELSE 'Instant Need' END AS dh_shopping_mission_user,
  CASE WHEN k.user_has_stock_up_v2 = 1 THEN 'Stock Up' WHEN k.user_has_fill_in_v2 = 1 THEN 'Fill In' ELSE 'Instant Need' END AS dh_shopping_mission_user_v2,

  CASE WHEN k.flag_plus >= 1 THEN 'Plus' WHEN k.crm_vertical = 'DMART' THEN 'Dmart RMO' WHEN k.flag_vc = 1 THEN k.order_source WHEN k.multibuy_order = 1 THEN 'Organic Multibuy' WHEN k.discount_order = 1 THEN 'Organic Discount' ELSE 'Organic' END AS order_source_level_two,
  CASE WHEN k.flag_plus > 1 THEN 'Plus Item Level' WHEN k.flag_plus = 1 AND k.d_bin_campaign IS NULL THEN 'Plus' WHEN k.flag_plus = 1 AND k.d_bin_campaign IS NOT NULL THEN 'Plus Benefit' WHEN k.crm_vertical = 'DMART' THEN 'Dmart RMO' WHEN k.flag_vc = 1 THEN k.order_source WHEN k.multibuy_order = 1 THEN 'Organic Multibuy' WHEN k.discount_order = 1 THEN 'Organic Discount' ELSE 'Organic' END AS order_source_level_three

FROM peru_dmarts_orders k;

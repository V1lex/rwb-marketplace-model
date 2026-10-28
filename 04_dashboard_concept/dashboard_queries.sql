-- Все цифры концепции дашборда «Обещание доставки», посчитанные из модели.
-- Запуск: bash scripts/psql.sh -f - < 04_dashboard_concept/dashboard_queries.sql
SET max_parallel_workers_per_gather = 0;

\echo '== KPI: верхний ряд'
SELECT count(*)                                                        AS orders,
       round(100.0 * count(*) FILTER (WHERE is_on_time) / count(*), 1) AS on_time_pct,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY delivery_days)      AS median_days,
       round(avg(promised_days), 1)                                    AS promised_days,
       round(avg(-delay_days), 1)                                      AS buffer_days,
       round(avg(review_score), 2)                                     AS avg_score,
       round(100.0 * count(*) FILTER (WHERE review_score <= 2) / count(review_score), 1) AS bad_pct,
       count(*) FILTER (WHERE NOT is_on_time)                          AS late_orders,
       sum(items_amount) FILTER (WHERE NOT is_on_time)                 AS late_revenue,
       sum(items_amount)                                               AS revenue
FROM mart.v_delivery;

\echo '== Опоздание отгрузки продавцом (доля единиц в заказах витрины)'
SELECT round(100.0 * count(*) FILTER (WHERE i.is_shipped_late) / count(*), 1) AS seller_late_pct
FROM core.fact_order_item i JOIN mart.v_delivery v USING (order_id);

\echo '== По месяцам'
SELECT to_char(purchase_month, 'YYYY-MM')                              AS month,
       count(*)                                                        AS orders,
       round(100.0 * count(*) FILTER (WHERE is_on_time) / count(*), 1) AS on_time_pct,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY delivery_days)      AS median_days,
       round(avg(promised_days), 1)                                    AS promised_days,
       round(avg(review_score), 2)                                     AS avg_score,
       round(avg(approval_hours) / 24, 2)                              AS approve_days,
       round(avg(seller_handling_days), 2)                             AS handling_days,
       round(avg(carrier_transit_days), 2)                             AS transit_days
FROM mart.v_delivery
GROUP BY purchase_month ORDER BY purchase_month;

\echo '== По штатам покупателя'
SELECT customer_state                                                  AS state,
       count(*)                                                        AS orders,
       round(100.0 * count(*) FILTER (WHERE is_on_time) / count(*), 1) AS on_time_pct,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY delivery_days)      AS median_days,
       round(avg(promised_days), 1)                                    AS promised_days,
       round(avg(review_score), 2)                                     AS avg_score
FROM mart.v_delivery
GROUP BY customer_state ORDER BY orders DESC;

\echo '== Оценка по опозданию'
SELECT CASE WHEN delay_days <= -15 THEN '1 раньше на 15+ дн.'
            WHEN delay_days <= -8  THEN '2 раньше на 8–14'
            WHEN delay_days <= -1  THEN '3 раньше на 1–7'
            WHEN delay_days =  0   THEN '4 день в день'
            WHEN delay_days <= 3   THEN '5 опоздал на 1–3'
            WHEN delay_days <= 7   THEN '6 опоздал на 4–7'
            WHEN delay_days <= 14  THEN '7 опоздал на 8–14'
            ELSE                        '8 опоздал на 15+' END        AS bucket,
       count(*)                                                        AS orders,
       round(avg(review_score), 2)                                     AS avg_score,
       round(100.0 * count(*) FILTER (WHERE review_score <= 2) / count(review_score), 1) AS bad_pct
FROM mart.v_delivery
GROUP BY 1 ORDER BY 1;

\echo '== Повторная покупка после первого заказа вовремя / с опозданием'
WITH first_order AS (
    SELECT DISTINCT ON (customer_sk) customer_sk, order_id
    FROM core.fact_order
    ORDER BY customer_sk, purchase_ts, order_id
), orders_per_customer AS (
    SELECT customer_sk, count(*) AS orders FROM core.fact_order GROUP BY customer_sk
)
SELECT CASE WHEN v.is_on_time THEN 'первый заказ вовремя' ELSE 'первый заказ опоздал' END AS grp,
       count(*)                                                                      AS customers,
       round(100.0 * count(*) FILTER (WHERE c.orders >= 2) / count(*), 2)            AS repeat_pct
FROM first_order f
JOIN mart.v_delivery v     ON v.order_id = f.order_id
JOIN orders_per_customer c ON c.customer_sk = f.customer_sk
GROUP BY 1 ORDER BY 1;

\echo '== Продавцы: распределение по доле опоздавших отгрузок (продавцы с 30+ единицами)'
WITH s AS (
    SELECT i.seller_sk, count(*) AS units,
           100.0 * count(*) FILTER (WHERE i.is_shipped_late) / count(*) AS late_pct
    FROM core.fact_order_item i JOIN mart.v_delivery v USING (order_id)
    GROUP BY i.seller_sk HAVING count(*) >= 30
)
SELECT least(floor(late_pct / 5), 10) AS band_no,
       CASE WHEN late_pct >= 50 THEN '50%+'
            ELSE (floor(late_pct / 5) * 5)::int || '–' || (floor(late_pct / 5) * 5 + 5)::int || '%' END AS band,
       count(*) AS sellers
FROM s GROUP BY 1, 2 ORDER BY 1;

\echo '== Топ продавцов по доле опоздавших отгрузок (200+ заказов)'
SELECT left(sl.seller_id, 8)                                            AS seller,
       sl.city, sl.state_code                                           AS state,
       count(DISTINCT i.order_id)                                       AS orders,
       round(100.0 * count(*) FILTER (WHERE i.is_shipped_late) / count(*), 1) AS late_ship_pct,
       round(avg(v.review_score), 2)                                    AS avg_score,
       sum(i.price)                                                     AS revenue
FROM core.fact_order_item i
JOIN mart.v_delivery v USING (order_id)
JOIN core.dim_seller sl USING (seller_sk)
GROUP BY sl.seller_id, sl.city, sl.state_code
HAVING count(DISTINCT i.order_id) >= 200
ORDER BY late_ship_pct DESC
LIMIT 10;

\echo '== Качество данных: что вошло в витрину'
SELECT count(*)                                                        AS orders_total,
       count(*) FILTER (WHERE s.is_revenue)                            AS delivered,
       (SELECT count(*) FROM mart.v_delivery)                          AS in_dashboard,
       count(*) FILTER (WHERE s.is_revenue AND o.is_delivered_without_date) AS no_delivery_date,
       count(*) FILTER (WHERE s.is_revenue AND o.is_chronology_broken AND NOT o.is_delivered_without_date) AS chronology_broken
FROM core.fact_order o JOIN core.dim_order_status s USING (order_status);

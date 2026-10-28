-- Q1. Выручка и число заказов по месяцам, сентябрь 2016 — август 2018
--
-- Решения:
--  * месяцы берём из календаря core.dim_date, а заказы присоединяем LEFT JOIN:
--    в ноябре 2016 заказов нет, но месяц обязан быть в отчёте с нулём;
--  * выручка = сумма цен товаров (без доставки) по заказам, статус которых
--    признаётся выручкой (dim_order_status.is_revenue: только delivered, выкуп);
--  * месяц — по дате оформления заказа;
--  * число заказов показываем двумя колонками: оформлено всего (спрос)
--    и выкуплено (заказы, давшие выручку).
-- Контроль: 24 строки, одна с нулевой выручкой, итого 13 221 498.11
SELECT d.year_month                                                AS month,
       count(o.order_id)                                           AS orders_placed,
       count(o.order_id) FILTER (WHERE s.is_revenue)               AS orders_delivered,
       coalesce(sum(o.items_amount) FILTER (WHERE s.is_revenue), 0) AS revenue
FROM core.dim_date d
LEFT JOIN core.fact_order o       ON o.purchase_date = d.calendar_date
LEFT JOIN core.dim_order_status s ON s.order_status = o.order_status
WHERE d.calendar_date >= DATE '2016-09-01'
  AND d.calendar_date <  DATE '2018-09-01'
GROUP BY d.year_month
ORDER BY d.year_month

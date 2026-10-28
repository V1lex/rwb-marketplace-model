-- Q2. Топ-10 продавцов по выручке, с городом и штатом
--
-- Решения:
--  * считаем на уровне позиции (fact_order_item): в заказе бывают товары
--    разных продавцов (1 278 заказов), и продавцу достаётся только его часть;
--  * выручка — то же правило, что в Q1: цена без доставки, статус is_revenue;
--  * заказы продавца — различные order_id, единицы — строки позиций
--    (одна строка fact_order_item = одна единица товара);
--  * город — нормализованный (core.dim_seller.city), штат — код.
-- Контроль: у первого продавца 226 987.93
SELECT sl.seller_id,
       sl.city,
       sl.state_code                   AS state,
       count(DISTINCT i.order_id)      AS orders,
       count(*)                        AS units,
       sum(i.price)                    AS revenue
FROM core.fact_order_item i
JOIN core.dim_order_status s USING (order_status)
JOIN core.dim_seller sl      USING (seller_sk)
WHERE s.is_revenue
GROUP BY sl.seller_id, sl.city, sl.state_code
ORDER BY revenue DESC
LIMIT 10

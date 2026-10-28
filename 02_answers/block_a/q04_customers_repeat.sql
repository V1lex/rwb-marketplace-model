-- Q4. Покупатели и повторные покупки
--
-- Решения:
--  * покупатель — человек (customer_unique_id → customer_sk). customer_id
--    в источнике выдаётся на каждый заказ заново: по нему вышло бы 99 441
--    «покупателей» и ни одного повторного;
--  * учитываем все оформленные заказы: вопрос о том, вернулся ли человек
--    за второй покупкой, а не о том, доставили ли её;
--  * вернувшийся — покупатель с двумя и более заказами.
-- Контроль: 96 096 покупателей, вернулись 3.12%
WITH per_customer AS (
    SELECT customer_sk, count(*) AS orders
    FROM core.fact_order
    GROUP BY customer_sk
)
SELECT count(*)                                              AS customers,
       count(*) FILTER (WHERE orders >= 2)                   AS returned_customers,
       round(100.0 * count(*) FILTER (WHERE orders >= 2) / count(*), 2) AS returned_pct
FROM per_customer

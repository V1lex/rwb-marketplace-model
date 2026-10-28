-- Q5. Выручка по категориям товаров с долей в общей выручке
--
-- Решения:
--  * 610 товаров без категории не выбрасываем: в dim_category для них есть
--    член «sem_categoria» (без категории), поэтому сумма по категориям
--    сходится с общей выручкой; это же проверяет dq (C05) при каждой сборке;
--  * у двух категорий нет перевода — показываем португальское название;
--  * доля — от общей выручки той же выборки (оконная сумма).
-- Контроль: 74 категории, у крупнейшей 1 233 131.72, сумма 13 221 498.11
SELECT c.category_code,
       c.category_name_en,
       sum(i.price)                                               AS revenue,
       round(100 * sum(i.price) / sum(sum(i.price)) OVER (), 2)   AS share_pct
FROM core.fact_order_item i
JOIN core.dim_order_status s USING (order_status)
JOIN core.dim_product p      USING (product_sk)
JOIN core.dim_category c     USING (category_sk)
WHERE s.is_revenue
GROUP BY c.category_code, c.category_name_en
ORDER BY revenue DESC

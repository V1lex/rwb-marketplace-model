-- Q3. Средний чек заказа
--
-- Решения:
--  * чек — свойство заказа: берём fact_order, где суммы позиций уже собраны
--    до уровня заказа (одна строка = один заказ);
--  * чек = товары + доставка (order_amount): столько покупатель платит за заказ;
--  * учитываем выкупленные заказы (is_revenue), как и выручку;
--  * строки заказа — разные пары (товар, продавец), единицы — штуки товара.
--    Единиц больше строк: один и тот же товар в нескольких экземплярах
--    лежит в источнике несколькими строками order_item_id.
-- Контроль: 159.88 (не 123.75 — средняя цена товара, не 139.97 — средняя позиция с доставкой)
SELECT round(avg(o.order_amount), 2) AS avg_order_value,
       round(avg(o.lines_count), 3)  AS avg_lines_per_order,
       round(avg(o.units_count), 3)  AS avg_units_per_order,
       count(*)                      AS orders
FROM core.fact_order o
JOIN core.dim_order_status s USING (order_status)
WHERE s.is_revenue

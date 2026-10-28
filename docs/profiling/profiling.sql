-- Профилирование сырых данных. Читает только raw, ничего не создаёт.
-- Запуск: psql -X -f docs/profiling/profiling.sql
-- Каждая строка результата: область, находка, значение.

-- В контейнере /dev/shm = 64 МБ, параллельный hash join на нём падает
-- с «could not resize shared memory segment». На 100 тыс. строк параллелизм не нужен.
SET max_parallel_workers_per_gather = 0;

WITH
items_per_order AS (
    SELECT order_id,
           count(*)                   AS units,
           count(DISTINCT product_id) AS products,
           count(DISTINCT seller_id)  AS sellers
    FROM raw.order_items
    GROUP BY order_id
),
item_totals AS (
    SELECT order_id, sum(price::numeric + freight_value::numeric) AS amount
    FROM raw.order_items GROUP BY order_id
),
payment_totals AS (
    SELECT order_id, sum(payment_value::numeric) AS amount,
           max(payment_sequential::int) AS max_seq, count(*) AS cnt
    FROM raw.order_payments GROUP BY order_id
),
o AS (
    SELECT order_id, order_status,
           order_purchase_timestamp::timestamp      AS purchase_ts,
           order_approved_at::timestamp             AS approved_ts,
           order_delivered_carrier_date::timestamp  AS carrier_ts,
           order_delivered_customer_date::timestamp AS delivered_ts
    FROM raw.orders
)
SELECT * FROM (VALUES
-- ключи
('ключи', 'raw.orders: строк / уникальных order_id',
    (SELECT count(*) || ' / ' || count(DISTINCT order_id) FROM raw.orders)),
('ключи', 'raw.customers: customer_id / customer_unique_id',
    (SELECT count(DISTINCT customer_id) || ' / ' || count(DISTINCT customer_unique_id) FROM raw.customers)),
('ключи', 'raw.order_items: строк / уникальных (order_id, order_item_id)',
    (SELECT count(*) || ' / ' || count(DISTINCT (order_id, order_item_id)) FROM raw.order_items)),
('ключи', 'raw.order_payments: строк / уникальных (order_id, payment_sequential)',
    (SELECT count(*) || ' / ' || count(DISTINCT (order_id, payment_sequential)) FROM raw.order_payments)),
('ключи', 'raw.order_reviews: строк / уникальных review_id / уникальных (review_id, order_id)',
    (SELECT count(*) || ' / ' || count(DISTINCT review_id) || ' / ' || count(DISTINCT (review_id, order_id)) FROM raw.order_reviews)),
('ключи', 'review_id, привязанных к нескольким заказам',
    (SELECT count(*)::text FROM (SELECT review_id FROM raw.order_reviews GROUP BY 1 HAVING count(*) > 1) x)),
('ключи', 'заказов с несколькими отзывами',
    (SELECT count(*)::text FROM (SELECT order_id FROM raw.order_reviews GROUP BY 1 HAVING count(*) > 1) x)),
('ключи', 'id не в формате 32 hex (orders, items)',
    (SELECT (SELECT count(*) FROM raw.orders WHERE order_id !~ '^[0-9a-f]{32}$' OR customer_id !~ '^[0-9a-f]{32}$')
          + (SELECT count(*) FROM raw.order_items WHERE product_id !~ '^[0-9a-f]{32}$' OR seller_id !~ '^[0-9a-f]{32}$'))::text),

-- связи
('связи', 'заказов без позиций', (SELECT count(*)::text FROM raw.orders r WHERE NOT EXISTS (SELECT 1 FROM raw.order_items i WHERE i.order_id = r.order_id))),
('связи', 'заказов без платежей', (SELECT count(*)::text FROM raw.orders r WHERE NOT EXISTS (SELECT 1 FROM raw.order_payments p WHERE p.order_id = r.order_id))),
('связи', 'заказов без отзыва', (SELECT count(*)::text FROM raw.orders r WHERE NOT EXISTS (SELECT 1 FROM raw.order_reviews v WHERE v.order_id = r.order_id))),
('связи', 'позиций/платежей/отзывов без заказа (сироты)',
    (SELECT ((SELECT count(*) FROM raw.order_items i WHERE NOT EXISTS (SELECT 1 FROM raw.orders r WHERE r.order_id = i.order_id))
           + (SELECT count(*) FROM raw.order_payments i WHERE NOT EXISTS (SELECT 1 FROM raw.orders r WHERE r.order_id = i.order_id))
           + (SELECT count(*) FROM raw.order_reviews i WHERE NOT EXISTS (SELECT 1 FROM raw.orders r WHERE r.order_id = i.order_id)))::text)),
('связи', 'позиций без товара или продавца в справочнике',
    (SELECT count(*)::text FROM raw.order_items i
     WHERE NOT EXISTS (SELECT 1 FROM raw.products p WHERE p.product_id = i.product_id)
        OR NOT EXISTS (SELECT 1 FROM raw.sellers s WHERE s.seller_id = i.seller_id))),
('связи', 'заказов без покупателя', (SELECT count(*)::text FROM raw.orders r WHERE NOT EXISTS (SELECT 1 FROM raw.customers c WHERE c.customer_id = r.customer_id))),

-- гранулярность
('гранулярность', 'единиц / разных товаров / продавцов на заказ (среднее)',
    (SELECT round(avg(units), 3) || ' / ' || round(avg(products), 3) || ' / ' || round(avg(sellers), 3) FROM items_per_order)),
('гранулярность', 'заказов с >1 единицей / с >1 продавцом',
    (SELECT count(*) FILTER (WHERE units > 1) || ' / ' || count(*) FILTER (WHERE sellers > 1) FROM items_per_order)),
('гранулярность', 'максимум единиц в заказе / платежей в заказе',
    (SELECT (SELECT max(units) FROM items_per_order) || ' / ' || (SELECT max(cnt) FROM payment_totals))),

-- статусы
('статусы', 'распределение order_status',
    (SELECT string_agg(order_status || '=' || n, ', ' ORDER BY n DESC)
     FROM (SELECT order_status, count(*) n FROM raw.orders GROUP BY 1) x)),
('статусы', 'delivered без даты вручения', (SELECT count(*)::text FROM o WHERE order_status = 'delivered' AND delivered_ts IS NULL)),
('статусы', 'canceled с датой вручения', (SELECT count(*)::text FROM o WHERE order_status = 'canceled' AND delivered_ts IS NOT NULL)),
('статусы', 'canceled / unavailable с позициями',
    (SELECT count(DISTINCT r.order_id) FILTER (WHERE r.order_status = 'canceled') || ' / ' ||
            count(DISTINCT r.order_id) FILTER (WHERE r.order_status = 'unavailable')
     FROM raw.orders r JOIN raw.order_items i USING (order_id))),

-- время
('время', 'диапазон order_purchase_timestamp',
    (SELECT min(purchase_ts) || ' .. ' || max(purchase_ts) FROM o)),
('время', 'заказов по месяцам 2016-09 .. 2016-12',
    (SELECT string_agg(m || '=' || n, ', ' ORDER BY m) FROM (
        SELECT to_char(d, 'YYYY-MM') m, count(o.order_id) n
        FROM generate_series('2016-09-01'::date, '2016-12-01', '1 month') d
        LEFT JOIN o ON date_trunc('month', o.purchase_ts) = d GROUP BY 1) x)),
('время', 'заказов после 2018-08 / из них delivered',
    (SELECT count(*) || ' / ' || count(*) FILTER (WHERE order_status = 'delivered') FROM o WHERE purchase_ts >= '2018-09-01')),
('время', 'пустых значений order_approved_at', (SELECT count(*)::text FROM o WHERE approved_ts IS NULL)),
('время', 'передан в доставку раньше оформления', (SELECT count(*)::text FROM o WHERE carrier_ts < purchase_ts)),
('время', 'передан в доставку раньше подтверждения оплаты', (SELECT count(*)::text FROM o WHERE carrier_ts < approved_ts)),
('время', 'вручён раньше передачи в доставку', (SELECT count(*)::text FROM o WHERE delivered_ts < carrier_ts)),
('время', 'shipping_limit_date позже 2018-12 (явная ошибка)', (SELECT count(*)::text FROM raw.order_items WHERE shipping_limit_date >= '2019-01-01')),
('время', 'обещанная дата доставки со временем ≠ 00:00', (SELECT count(*)::text FROM raw.orders WHERE order_estimated_delivery_date NOT LIKE '% 00:00:00')),

-- деньги
('деньги', 'price: min / max / ≤0',
    (SELECT min(price::numeric) || ' / ' || max(price::numeric) || ' / ' || count(*) FILTER (WHERE price::numeric <= 0) FROM raw.order_items)),
('деньги', 'позиций с бесплатной доставкой (freight = 0)', (SELECT count(*)::text FROM raw.order_items WHERE freight_value::numeric = 0)),
('деньги', 'payment_type',
    (SELECT string_agg(payment_type || '=' || n, ', ' ORDER BY n DESC) FROM (SELECT payment_type, count(*) n FROM raw.order_payments GROUP BY 1) x)),
('деньги', 'платежей с installments = 0 / с payment_value = 0',
    (SELECT count(*) FILTER (WHERE payment_installments::int = 0) || ' / ' || count(*) FILTER (WHERE payment_value::numeric = 0) FROM raw.order_payments)),
('деньги', 'заказов с дырами в payment_sequential', (SELECT count(*)::text FROM payment_totals WHERE max_seq <> cnt)),
('деньги', 'заказов: оплата ≠ товары + доставка (> 0.01)',
    (SELECT count(*)::text FROM item_totals i JOIN payment_totals p USING (order_id) WHERE abs(i.amount - p.amount) > 0.01)),
('деньги', 'оплачено по заказам без позиций, сумма',
    (SELECT round(sum(p.amount), 2)::text FROM payment_totals p WHERE NOT EXISTS (SELECT 1 FROM item_totals i WHERE i.order_id = p.order_id))),
('деньги', 'товаров с разной ценой в разных заказах', (SELECT count(*)::text FROM (SELECT product_id FROM raw.order_items GROUP BY 1 HAVING count(DISTINCT price) > 1) x)),

-- справочники
('справочники', 'товаров без категории', (SELECT count(*)::text FROM raw.products WHERE product_category_name IS NULL)),
('справочники', 'категорий в товарах / в справочнике перевода',
    (SELECT (SELECT count(DISTINCT product_category_name) FROM raw.products) || ' / ' || (SELECT count(*) FROM raw.product_category_translation))),
('справочники', 'категории без перевода',
    (SELECT string_agg(DISTINCT p.product_category_name, ', ') FROM raw.products p
     WHERE p.product_category_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM raw.product_category_translation t WHERE t.product_category_name = p.product_category_name))),
('справочники', 'товаров без веса / без габаритов', (SELECT count(*) FILTER (WHERE product_weight_g IS NULL) || ' / ' || count(*) FILTER (WHERE product_length_cm IS NULL) FROM raw.products)),
('справочники', 'индексов продавцов короче 5 знаков (потерян ведущий ноль)', (SELECT count(*)::text FROM raw.sellers WHERE length(seller_zip_code_prefix) < 5)),
('справочники', 'индексов покупателей короче 5 знаков', (SELECT count(*)::text FROM raw.customers WHERE length(customer_zip_code_prefix) < 5)),
('справочники', 'городов продавцов с мусором (штат, слэш, email, цифры, диакритика)',
    (SELECT count(*)::text FROM raw.sellers WHERE seller_city ~ '[^a-z '']' )),
('справочники', 'штатов продавцов / покупателей',
    (SELECT (SELECT count(DISTINCT seller_state) FROM raw.sellers) || ' / ' || (SELECT count(DISTINCT customer_state) FROM raw.customers))),

-- история
('история', 'покупателей (unique_id) с несколькими адресами',
    (SELECT count(*)::text FROM (SELECT customer_unique_id FROM raw.customers GROUP BY 1
     HAVING count(DISTINCT (customer_zip_code_prefix, customer_city, customer_state)) > 1) x)),

-- отзывы
('отзывы', 'распределение review_score',
    (SELECT string_agg(review_score || '=' || n, ', ' ORDER BY review_score) FROM (SELECT review_score, count(*) n FROM raw.order_reviews GROUP BY 1) x)),
('отзывы', 'с заголовком / с текстом',
    (SELECT count(review_comment_title) || ' / ' || count(review_comment_message) FROM raw.order_reviews))
) AS t(area, finding, value);

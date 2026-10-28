-- =====================================================================
--  90. DQ: самопроверки сборки
--
--  Каждая проверка — строка в dq.check_result: что сравниваем,
--  ожидаемое и фактическое значение. Уровни:
--    error — модель неверна; сборка откатывается целиком (RAISE в конце);
--    warn  — данные требуют внимания, модель корректна.
--  Отчёт: SELECT * FROM dq.check_result ORDER BY check_code;
-- =====================================================================

CREATE TABLE dq.check_result (
    check_code      text        PRIMARY KEY,
    severity        text        NOT NULL CHECK (severity IN ('error', 'warn')),
    description     text        NOT NULL,
    expected        numeric,
    actual          numeric,
    passed          boolean     GENERATED ALWAYS AS (expected IS NOT DISTINCT FROM actual) STORED,
    checked_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE dq.check_result IS 'Результаты самопроверок последней сборки. error — критично (сборка откатывается), warn — информативно';

INSERT INTO dq.check_result (check_code, severity, description, expected, actual)

-- ---------- R: сверка raw ↔ core — ничего не потеряли и не размножили
          SELECT 'R01', 'error', 'Заказы: уникальных order_id в raw = строк в fact_order',
                 (SELECT count(DISTINCT order_id) FROM raw.orders), (SELECT count(*) FROM core.fact_order)
UNION ALL SELECT 'R02', 'error', 'Позиции: уникальных (order_id, order_item_id) в raw = строк в fact_order_item',
                 (SELECT count(DISTINCT (order_id, order_item_id)) FROM raw.order_items), (SELECT count(*) FROM core.fact_order_item)
UNION ALL SELECT 'R03', 'error', 'Платежи: уникальных (order_id, payment_sequential) в raw = строк в fact_payment',
                 (SELECT count(DISTINCT (order_id, payment_sequential)) FROM raw.order_payments), (SELECT count(*) FROM core.fact_payment)
UNION ALL SELECT 'R04', 'error', 'Отзывы: уникальных (review_id, order_id) в raw = строк в fact_review',
                 (SELECT count(DISTINCT (review_id, order_id)) FROM raw.order_reviews), (SELECT count(*) FROM core.fact_review)
UNION ALL SELECT 'R05', 'error', 'Товары: raw = dim_product без члена -1',
                 (SELECT count(DISTINCT product_id) FROM raw.products), (SELECT count(*) FROM core.dim_product WHERE product_sk > 0)
UNION ALL SELECT 'R06', 'error', 'Продавцы: raw = dim_seller без члена -1',
                 (SELECT count(DISTINCT seller_id) FROM raw.sellers), (SELECT count(*) FROM core.dim_seller WHERE seller_sk > 0)
UNION ALL SELECT 'R07', 'error', 'Покупатели: уникальных customer_unique_id в raw = dim_customer без члена -1',
                 (SELECT count(DISTINCT customer_unique_id) FROM raw.customers), (SELECT count(*) FROM core.dim_customer WHERE customer_sk > 0)
UNION ALL SELECT 'R08', 'error', 'Сумма price: raw = fact_order_item',
                 (SELECT sum(price::numeric) FROM raw.order_items), (SELECT sum(price) FROM core.fact_order_item)
UNION ALL SELECT 'R09', 'error', 'Сумма freight_value: raw = fact_order_item',
                 (SELECT sum(freight_value::numeric) FROM raw.order_items), (SELECT sum(freight_value) FROM core.fact_order_item)
UNION ALL SELECT 'R10', 'error', 'Сумма payment_value: raw = fact_payment',
                 (SELECT sum(payment_value::numeric) FROM raw.order_payments), (SELECT sum(payment_value) FROM core.fact_payment)
UNION ALL SELECT 'R11', 'error', 'Категории: в товарах + справочнике перевода = dim_category без служебных членов',
                 (SELECT count(*) FROM (SELECT product_category_name FROM raw.products WHERE product_category_name IS NOT NULL
                                        UNION SELECT product_category_name FROM raw.product_category_translation) c),
                 (SELECT count(*) FROM core.dim_category WHERE NOT is_unlabeled)

-- ---------- C: внутренняя согласованность core
UNION ALL SELECT 'C01', 'error', 'fact_order.items_amount = сумма price по fact_order_item',
                 (SELECT sum(price) FROM core.fact_order_item), (SELECT sum(items_amount) FROM core.fact_order)
UNION ALL SELECT 'C02', 'error', 'fact_order.units_count = строк fact_order_item',
                 (SELECT count(*) FROM core.fact_order_item), (SELECT sum(units_count) FROM core.fact_order)
UNION ALL SELECT 'C03', 'error', 'fact_order.payment_amount = сумма fact_payment',
                 (SELECT sum(payment_value) FROM core.fact_payment), (SELECT sum(payment_amount) FROM core.fact_order)
UNION ALL SELECT 'C04', 'error', 'Ровно один последний отзыв на каждый заказ с отзывами',
                 (SELECT count(DISTINCT order_id) FROM core.fact_review), (SELECT count(*) FROM core.fact_review WHERE is_latest_for_order)
UNION ALL SELECT 'C05', 'error', 'Выручка по категориям = общая выручка (ни одна позиция не потеряна на JOIN)',
                 (SELECT sum(i.price) FROM core.fact_order_item i JOIN core.dim_order_status s USING (order_status) WHERE s.is_revenue),
                 (SELECT sum(i.price) FROM core.fact_order_item i
                    JOIN core.dim_order_status s USING (order_status)
                    JOIN core.dim_product p USING (product_sk)
                    JOIN core.dim_category c USING (category_sk) WHERE s.is_revenue)
UNION ALL SELECT 'C06', 'error', 'Статус в позиции совпадает со статусом её заказа',
                 0, (SELECT count(*) FROM core.fact_order_item i JOIN core.fact_order o USING (order_id) WHERE i.order_status <> o.order_status)

-- ---------- P: значения, которые не удалось разобрать (raw не пуст, а типизированное NULL)
UNION ALL SELECT 'P01', 'warn', 'Нераспознанные даты в заказах', 0,
                 (SELECT count(*) FROM raw.orders r JOIN stg.orders s USING (order_id)
                  WHERE (r.order_purchase_timestamp IS NOT NULL AND s.purchase_ts IS NULL)
                     OR (r.order_approved_at IS NOT NULL AND s.approved_ts IS NULL)
                     OR (r.order_delivered_carrier_date IS NOT NULL AND s.delivered_carrier_ts IS NULL)
                     OR (r.order_delivered_customer_date IS NOT NULL AND s.delivered_customer_ts IS NULL)
                     OR (r.order_estimated_delivery_date IS NOT NULL AND s.estimated_delivery_date IS NULL))
UNION ALL SELECT 'P02', 'warn', 'Нераспознанные числа и даты в позициях', 0,
                 (SELECT count(*) FROM raw.order_items r
                  WHERE stg.to_int(r.order_item_id) IS NULL
                     OR (r.price IS NOT NULL AND stg.to_numeric(r.price) IS NULL)
                     OR (r.freight_value IS NOT NULL AND stg.to_numeric(r.freight_value) IS NULL)
                     OR (r.shipping_limit_date IS NOT NULL AND stg.to_timestamp(r.shipping_limit_date) IS NULL))
UNION ALL SELECT 'P03', 'warn', 'Нераспознанные числа в платежах', 0,
                 (SELECT count(*) FROM raw.order_payments r
                  WHERE stg.to_int(r.payment_sequential) IS NULL
                     OR (r.payment_installments IS NOT NULL AND stg.to_int(r.payment_installments) IS NULL)
                     OR (r.payment_value IS NOT NULL AND stg.to_numeric(r.payment_value) IS NULL))
UNION ALL SELECT 'P04', 'warn', 'Нераспознанные оценки и даты в отзывах', 0,
                 (SELECT count(*) FROM raw.order_reviews r
                  WHERE (r.review_score IS NOT NULL AND stg.to_int(r.review_score) IS NULL)
                     OR (r.review_creation_date IS NOT NULL AND stg.to_timestamp(r.review_creation_date) IS NULL)
                     OR (r.review_answer_timestamp IS NOT NULL AND stg.to_timestamp(r.review_answer_timestamp) IS NULL))
UNION ALL SELECT 'P05', 'warn', 'Дубликаты строк в raw, снятые дедупликацией stg', 0,
                 (SELECT (SELECT count(*) FROM raw.orders) - (SELECT count(*) FROM stg.orders)
                       + (SELECT count(*) FROM raw.order_items) - (SELECT count(*) FROM stg.order_items)
                       + (SELECT count(*) FROM raw.order_payments) - (SELECT count(*) FROM stg.order_payments)
                       + (SELECT count(*) FROM raw.order_reviews) - (SELECT count(*) FROM stg.order_reviews))

-- ---------- I: ссылки на члены «неизвестно» и неописанные значения справочников
UNION ALL SELECT 'I01', 'warn', 'Позиции со ссылкой на неизвестный товар или продавца (-1)', 0,
                 (SELECT count(*) FROM core.fact_order_item WHERE product_sk = -1 OR seller_sk = -1)
UNION ALL SELECT 'I02', 'warn', 'Заказы со ссылкой на неизвестного покупателя (-1)', 0,
                 (SELECT count(*) FROM core.fact_order WHERE customer_sk = -1)
UNION ALL SELECT 'I03', 'warn', 'Неописанные значения справочников (статусы, типы оплаты, штаты)', 0,
                 (SELECT (SELECT count(*) FROM core.dim_order_status WHERE NOT is_documented)
                       + (SELECT count(*) FROM core.dim_payment_type WHERE NOT is_documented)
                       + (SELECT count(*) FROM core.dim_state WHERE NOT is_documented))
UNION ALL SELECT 'I04', 'warn', 'Товары с категорией, отсутствующей в справочнике (-1)', 0,
                 (SELECT count(*) FROM core.dim_product WHERE category_sk = -1 AND product_sk > 0)

-- ---------- B: известные особенности данных. Ожидаемое = значение при профилировании;
--            если новая порция данных его меняет, предупреждение подсказывает, где смотреть
UNION ALL SELECT 'B01', 'warn', 'Заказы без позиций',               775, (SELECT count(*) FROM core.fact_order WHERE NOT has_items)
UNION ALL SELECT 'B02', 'warn', 'Заказы без платежей',              1,   (SELECT count(*) FROM core.fact_order WHERE NOT has_payment)
UNION ALL SELECT 'B03', 'warn', 'Заказы: оплачено ≠ товары + доставка', 366, (SELECT count(*) FROM core.fact_order WHERE is_payment_mismatch)
UNION ALL SELECT 'B04', 'warn', 'Заказы с нарушенной хронологией',  189, (SELECT count(*) FROM core.fact_order WHERE is_chronology_broken)
UNION ALL SELECT 'B05', 'warn', 'delivered без даты вручения',      8,   (SELECT count(*) FROM core.fact_order WHERE is_delivered_without_date)
UNION ALL SELECT 'B06', 'warn', 'Отменённые с датой вручения',      6,   (SELECT count(*) FROM core.fact_order WHERE is_cancelled_with_delivery)
UNION ALL SELECT 'B07', 'warn', 'Товары без категории',             610, (SELECT count(*) FROM core.dim_product WHERE category_sk = 0)
UNION ALL SELECT 'B08', 'warn', 'Категории без перевода',           2,   (SELECT count(*) FROM core.dim_category WHERE NOT is_translated AND NOT is_unlabeled)
UNION ALL SELECT 'B09', 'warn', 'Позиции с подозрительным сроком отгрузки (> 1 года)', 4,
                 (SELECT count(*) FROM core.fact_order_item WHERE is_shipping_limit_suspicious)
UNION ALL SELECT 'B10', 'warn', 'Продавцы без распознанного города', 7, (SELECT count(*) FROM core.dim_seller WHERE seller_sk > 0 AND city IS NULL);

-- Провал любой проверки уровня error откатывает всю сборку
DO $$
DECLARE
    failed text;
BEGIN
    SELECT string_agg(format('%s %s: ожидали %s, получили %s', check_code, description, expected, actual), E'\n')
      INTO failed
      FROM dq.check_result
     WHERE severity = 'error' AND NOT passed;

    IF failed IS NOT NULL THEN
        RAISE EXCEPTION E'Самопроверки не пройдены, сборка откатывается:\n%', failed;
    END IF;
END $$;

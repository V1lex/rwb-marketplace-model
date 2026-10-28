-- =====================================================================
--  10. STG (ODS): типизация и чистка поверх raw
--
--  Слой материализуется таблицами: каждая строка raw чистится ровно один
--  раз, а core читает уже готовые типизированные данные. Представления
--  пересчитывались бы при каждом обращении (сборка шла 2 минуты вместо секунд).
--
--  Правила, единые для всех таблиц слоя:
--   * текст: trim, пустая строка → NULL;
--   * типы приводятся «мягко» функциями stg.to_*: значение, которое не
--     разбирается, становится NULL и попадает в счётчик сверки
--     dq «P*_unparsed». Одна битая строка не роняет сборку, но и не
--     теряется молча;
--   * дедупликация по натуральному ключу: при повторной дозагрузке
--     в raw побеждает строка с самым поздним _loaded_at.
-- =====================================================================

-- ---------------------------------------------------------------------
--  Функции мягкого приведения типов. SQL-функции без исключений:
--  планировщик встраивает их в запрос, на 100 тыс. строк это бесплатно.
-- ---------------------------------------------------------------------

CREATE FUNCTION stg.clean_text(v text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT nullif(btrim(v), '') $$;

CREATE FUNCTION stg.to_timestamp(v text) RETURNS timestamp
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT CASE
        WHEN btrim(v) ~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2}(\.\d+)?)?)?$'
        THEN btrim(v)::timestamp
    END
$$;

CREATE FUNCTION stg.to_numeric(v text) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT CASE WHEN btrim(v) ~ '^-?\d+(\.\d+)?$' THEN btrim(v)::numeric END $$;

CREATE FUNCTION stg.to_int(v text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT CASE WHEN btrim(v) ~ '^-?\d{1,9}(\.0+)?$' THEN btrim(v)::numeric::integer END $$;

-- Почтовый префикс: в выгрузке потерян ведущий ноль («1001» вместо «01001»).
CREATE FUNCTION stg.to_zip_prefix(v text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT CASE WHEN btrim(v) ~ '^\d{1,5}$' THEN lpad(btrim(v), 5, '0') END $$;

COMMENT ON FUNCTION stg.to_timestamp(text) IS 'text → timestamp; нераспознанное значение → NULL (учитывается в dq)';
COMMENT ON FUNCTION stg.to_numeric(text)   IS 'text → numeric; нераспознанное значение → NULL (учитывается в dq)';
COMMENT ON FUNCTION stg.to_int(text)       IS 'text → integer; нераспознанное значение → NULL (учитывается в dq)';
COMMENT ON FUNCTION stg.to_zip_prefix(text) IS 'Почтовый префикс из 5 цифр: восстанавливает потерянный ведущий ноль';

-- Город: в справочнике продавцов встречаются «sao paulo - sp», «sbc/sp»,
-- «rio de janeiro, rio de janeiro, brasil», «são paulo» (в форме NFD),
-- email и цифры. Порядок: нижний регистр → снять диакритику (NFD и удаление
-- комбинируемых знаков) → отрезать всё после «/ \ ,» и скобки → отрезать
-- хвост, равный штату этой же строки («sao paulo sp» при штате SP; при этом
-- «sento se» в штате BA остаётся городом Сенту-Се) → схлопнуть пробелы.
-- То, в чём нет букв, есть «@» или что целиком равно коду штата, городом не считаем.
CREATE FUNCTION stg.normalize_city(v text, state_code text) RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$$
DECLARE
    c  text := lower(btrim(v));
    st text := lower(btrim(coalesce(state_code, '')));
BEGIN
    IF c IS NULL OR c = '' THEN
        RETURN NULL;
    END IF;
    -- диакритика: NFD раскладывает «ã» на «a» + комбинируемый знак, знак удаляем
    c := regexp_replace(normalize(c, NFD), '[̀-ͯ]', '', 'g');
    c := replace(replace(c, '´', ''''), '`', '''');
    -- всё после «/», «\», «,» и скобки — уточнения (штат, страна, район)
    c := split_part(split_part(split_part(c, '/', 1), '\', 1), ',', 1);
    c := btrim(regexp_replace(c, '\(.*$', ''));
    -- хвост «- sp» / « sp», только если это штат этой же строки
    IF st <> '' THEN
        c := btrim(regexp_replace(c, '[\s-]+' || st || '$', ''));
    END IF;
    c := regexp_replace(c, '\s+', ' ', 'g');

    IF c = '' OR c ~ '@' OR c !~ '[a-z]' OR c = st THEN
        RETURN NULL;
    END IF;
    IF c = 'sbc' THEN
        RETURN 'sao bernardo do campo';
    END IF;
    RETURN c;
END
$$;

COMMENT ON FUNCTION stg.normalize_city(text, text) IS
    'Нормализация города: регистр, диакритика, хвосты «/ штат», «- sp», «, brasil»; email, цифры, код штата → NULL';

-- ---------------------------------------------------------------------
--  Таблицы слоя
-- ---------------------------------------------------------------------

CREATE TABLE stg.orders AS
SELECT DISTINCT ON (order_id)
    order_id,
    customer_id,
    coalesce(lower(stg.clean_text(order_status)), 'unknown') AS order_status,   -- пустой статус не теряем
    stg.to_timestamp(order_purchase_timestamp)              AS purchase_ts,
    stg.to_timestamp(order_approved_at)                     AS approved_ts,
    stg.to_timestamp(order_delivered_carrier_date)          AS delivered_carrier_ts,
    stg.to_timestamp(order_delivered_customer_date)         AS delivered_customer_ts,
    stg.to_timestamp(order_estimated_delivery_date)::date   AS estimated_delivery_date,
    _loaded_at
FROM (
    SELECT stg.clean_text(order_id) AS order_id, stg.clean_text(customer_id) AS customer_id,
           order_status, order_purchase_timestamp, order_approved_at,
           order_delivered_carrier_date, order_delivered_customer_date,
           order_estimated_delivery_date, _loaded_at
    FROM raw.orders
) r
WHERE order_id IS NOT NULL
ORDER BY order_id, _loaded_at DESC;

CREATE TABLE stg.order_items AS
SELECT DISTINCT ON (order_id, order_item_id)
    order_id,
    order_item_id,
    stg.clean_text(product_id)              AS product_id,
    stg.clean_text(seller_id)               AS seller_id,
    stg.to_timestamp(shipping_limit_date)   AS shipping_limit_ts,
    stg.to_numeric(price)::numeric(12,2)         AS price,
    stg.to_numeric(freight_value)::numeric(12,2) AS freight_value,
    _loaded_at
FROM (
    SELECT stg.clean_text(order_id) AS order_id, stg.to_int(order_item_id) AS order_item_id,
           product_id, seller_id, shipping_limit_date, price, freight_value, _loaded_at
    FROM raw.order_items
) r
WHERE order_id IS NOT NULL AND order_item_id IS NOT NULL
ORDER BY order_id, order_item_id, _loaded_at DESC;

CREATE TABLE stg.order_payments AS
SELECT DISTINCT ON (order_id, payment_sequential)
    order_id,
    payment_sequential,
    lower(stg.clean_text(payment_type))           AS payment_type,
    stg.to_int(payment_installments)              AS payment_installments,
    stg.to_numeric(payment_value)::numeric(12,2)  AS payment_value,
    _loaded_at
FROM (
    SELECT stg.clean_text(order_id) AS order_id, stg.to_int(payment_sequential) AS payment_sequential,
           payment_type, payment_installments, payment_value, _loaded_at
    FROM raw.order_payments
) r
WHERE order_id IS NOT NULL AND payment_sequential IS NOT NULL
ORDER BY order_id, payment_sequential, _loaded_at DESC;

CREATE TABLE stg.order_reviews AS
SELECT DISTINCT ON (review_id, order_id)
    review_id,
    order_id,
    stg.to_int(review_score)                     AS review_score,
    stg.clean_text(review_comment_title)         AS comment_title,
    stg.clean_text(review_comment_message)       AS comment_message,
    stg.to_timestamp(review_creation_date)       AS creation_ts,
    stg.to_timestamp(review_answer_timestamp)    AS answer_ts,
    _loaded_at
FROM (
    SELECT stg.clean_text(review_id) AS review_id, stg.clean_text(order_id) AS order_id,
           review_score, review_comment_title, review_comment_message,
           review_creation_date, review_answer_timestamp, _loaded_at
    FROM raw.order_reviews
) r
WHERE review_id IS NOT NULL AND order_id IS NOT NULL
ORDER BY review_id, order_id, _loaded_at DESC;

CREATE TABLE stg.products AS
SELECT DISTINCT ON (product_id)
    product_id,
    lower(stg.clean_text(product_category_name))   AS category_code,
    stg.to_int(product_name_lenght)                AS name_length,        -- опечатка источника исправлена
    stg.to_int(product_description_lenght)         AS description_length,
    stg.to_int(product_photos_qty)                 AS photos_qty,
    stg.to_int(product_weight_g)                   AS weight_g,
    stg.to_int(product_length_cm)                  AS length_cm,
    stg.to_int(product_height_cm)                  AS height_cm,
    stg.to_int(product_width_cm)                   AS width_cm,
    _loaded_at
FROM (
    SELECT stg.clean_text(product_id) AS product_id, product_category_name,
           product_name_lenght, product_description_lenght, product_photos_qty,
           product_weight_g, product_length_cm, product_height_cm, product_width_cm, _loaded_at
    FROM raw.products
) r
WHERE product_id IS NOT NULL
ORDER BY product_id, _loaded_at DESC;

CREATE TABLE stg.sellers AS
SELECT DISTINCT ON (seller_id)
    seller_id,
    stg.to_zip_prefix(seller_zip_code_prefix)  AS zip_prefix,
    stg.normalize_city(seller_city, seller_state) AS city,
    stg.clean_text(seller_city)                AS city_raw,
    upper(stg.clean_text(seller_state))        AS state_code,
    _loaded_at
FROM (
    SELECT stg.clean_text(seller_id) AS seller_id, seller_zip_code_prefix,
           seller_city, seller_state, _loaded_at
    FROM raw.sellers
) r
WHERE seller_id IS NOT NULL
ORDER BY seller_id, _loaded_at DESC;

CREATE TABLE stg.customers AS
SELECT DISTINCT ON (customer_id)
    customer_id,
    stg.clean_text(customer_unique_id)           AS customer_unique_id,
    stg.to_zip_prefix(customer_zip_code_prefix)  AS zip_prefix,
    stg.normalize_city(customer_city, customer_state) AS city,
    upper(stg.clean_text(customer_state))        AS state_code,
    _loaded_at
FROM (
    SELECT stg.clean_text(customer_id) AS customer_id, customer_unique_id,
           customer_zip_code_prefix, customer_city, customer_state, _loaded_at
    FROM raw.customers
) r
WHERE customer_id IS NOT NULL
ORDER BY customer_id, _loaded_at DESC;

CREATE TABLE stg.category_translation AS
SELECT DISTINCT ON (category_code)
    category_code,
    lower(stg.clean_text(product_category_name_english)) AS category_name_en,
    _loaded_at
FROM (
    SELECT lower(stg.clean_text(product_category_name)) AS category_code,
           product_category_name_english, _loaded_at
    FROM raw.product_category_translation
) r
WHERE category_code IS NOT NULL
ORDER BY category_code, _loaded_at DESC;

COMMENT ON TABLE stg.orders         IS 'Заказы: типизированы даты, статус в нижнем регистре, дедупликация по order_id';
COMMENT ON TABLE stg.order_items    IS 'Позиции: одна строка = одна единица товара, ключ (order_id, order_item_id)';
COMMENT ON TABLE stg.order_payments IS 'Платежи: ключ (order_id, payment_sequential)';
COMMENT ON TABLE stg.order_reviews  IS 'Отзывы: ключ (review_id, order_id), review_id сам по себе не уникален';
COMMENT ON TABLE stg.products       IS 'Товары: исправлена опечатка lenght → length, категория в нижнем регистре';
COMMENT ON TABLE stg.sellers        IS 'Продавцы: префикс индекса из 5 цифр, нормализованный город (city_raw — как в источнике)';
COMMENT ON TABLE stg.customers      IS 'Покупатели в разрезе заказа: customer_id — снимок адреса, человек — customer_unique_id';
COMMENT ON TABLE stg.category_translation IS 'Перевод категорий PT → EN';

ANALYZE stg.orders, stg.order_items, stg.order_payments, stg.order_reviews,
        stg.products, stg.sellers, stg.customers, stg.category_translation;

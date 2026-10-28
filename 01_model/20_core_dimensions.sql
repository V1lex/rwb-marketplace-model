-- =====================================================================
--  20. CORE: измерения
--
--  Конвенции:
--   * Суррогатный ключ *_sk (integer) — для связей фактов с измерениями.
--     Натуральный ключ источника хранится рядом с UNIQUE-ограничением.
--   * Член «неизвестно» с ключом -1 есть в каждом измерении с суррогатным
--     ключом: если в будущей порции данных позиция сошлётся на товар,
--     которого нет в справочнике, строка не потеряется на JOIN, а уйдёт
--     на -1 и будет видна в сверке dq.
--   * Справочники с бизнес-правилами (статусы, типы оплаты, штаты)
--     задаются здесь явно. Значение, которое придёт из данных и которого
--     нет в справочнике, добавляется автоматически с флагом
--     is_documented = false, и dq выдаёт предупреждение.
-- =====================================================================

-- ---------------------------------------------------------------------
--  dim_date — календарь. Отчёты по периодам строятся от него, иначе
--  месяц без заказов (ноябрь 2016) из отчёта просто исчезнет.
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_date (
    calendar_date   date        PRIMARY KEY,
    year            smallint    NOT NULL,
    quarter         smallint    NOT NULL,
    month           smallint    NOT NULL,
    month_start     date        NOT NULL,
    year_month      text     NOT NULL,
    iso_year        smallint    NOT NULL,
    iso_week        smallint    NOT NULL,
    day_of_week     smallint    NOT NULL,
    day_name        text        NOT NULL,
    is_weekend      boolean     NOT NULL
);

INSERT INTO core.dim_date
SELECT d::date,
       extract(year    FROM d),
       extract(quarter FROM d),
       extract(month   FROM d),
       date_trunc('month', d)::date,
       to_char(d, 'YYYY-MM'),
       extract(isoyear FROM d),
       extract(week    FROM d),
       extract(isodow  FROM d),
       (ARRAY['Пн','Вт','Ср','Чт','Пт','Сб','Вс'])[extract(isodow FROM d)],
       extract(isodow FROM d) IN (6, 7)
FROM generate_series('2016-01-01'::date, '2020-12-31'::date, interval '1 day') AS d;

COMMENT ON TABLE  core.dim_date IS 'Календарь 2016–2020 (покрывает shipping_limit_date до 2020-04). Зерно: день';
COMMENT ON COLUMN core.dim_date.month_start IS 'Первый день месяца: ключ для помесячных отчётов';
COMMENT ON COLUMN core.dim_date.day_of_week IS 'ISO: 1 = понедельник … 7 = воскресенье';

-- ---------------------------------------------------------------------
--  dim_state — штаты Бразилии и макрорегионы (справочник IBGE)
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_state (
    state_code      text     PRIMARY KEY,
    state_name      text        NOT NULL,
    region          text        NOT NULL,
    is_documented   boolean     NOT NULL DEFAULT true
);

INSERT INTO core.dim_state (state_code, state_name, region) VALUES
    ('AC','Acre','Norte'), ('AP','Amapá','Norte'), ('AM','Amazonas','Norte'),
    ('PA','Pará','Norte'), ('RO','Rondônia','Norte'), ('RR','Roraima','Norte'),
    ('TO','Tocantins','Norte'),
    ('AL','Alagoas','Nordeste'), ('BA','Bahia','Nordeste'), ('CE','Ceará','Nordeste'),
    ('MA','Maranhão','Nordeste'), ('PB','Paraíba','Nordeste'), ('PE','Pernambuco','Nordeste'),
    ('PI','Piauí','Nordeste'), ('RN','Rio Grande do Norte','Nordeste'), ('SE','Sergipe','Nordeste'),
    ('DF','Distrito Federal','Centro-Oeste'), ('GO','Goiás','Centro-Oeste'),
    ('MT','Mato Grosso','Centro-Oeste'), ('MS','Mato Grosso do Sul','Centro-Oeste'),
    ('ES','Espírito Santo','Sudeste'), ('MG','Minas Gerais','Sudeste'),
    ('RJ','Rio de Janeiro','Sudeste'), ('SP','São Paulo','Sudeste'),
    ('PR','Paraná','Sul'), ('RS','Rio Grande do Sul','Sul'), ('SC','Santa Catarina','Sul');

INSERT INTO core.dim_state (state_code, state_name, region, is_documented)
SELECT DISTINCT s.state_code, 'не описан', 'не описан', false
FROM (SELECT state_code FROM stg.sellers UNION SELECT state_code FROM stg.customers) s
WHERE s.state_code IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM core.dim_state d WHERE d.state_code = s.state_code);

COMMENT ON TABLE core.dim_state IS 'Штаты Бразилии (27) и макрорегионы IBGE. Зерно: штат';

-- ---------------------------------------------------------------------
--  dim_order_status — жизненный цикл заказа. Здесь живёт правило
--  «что считается выручкой»: is_revenue. Поменяется правило — меняем
--  одну строку, а не каждый запрос.
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_order_status (
    order_status    text        PRIMARY KEY,
    status_name_ru  text        NOT NULL,
    stage_order     smallint    NOT NULL,
    is_revenue      boolean     NOT NULL,
    is_cancelled    boolean     NOT NULL,
    is_final        boolean     NOT NULL,
    is_documented   boolean     NOT NULL DEFAULT true
);

INSERT INTO core.dim_order_status
    (order_status, status_name_ru, stage_order, is_revenue, is_cancelled, is_final) VALUES
    ('created',     'Создан',                      1, false, false, false),
    ('approved',    'Оплата подтверждена',         2, false, false, false),
    ('invoiced',    'Выставлен счёт',              3, false, false, false),
    ('processing',  'Собирается продавцом',        4, false, false, false),
    ('shipped',     'Передан в доставку',          5, false, false, false),
    ('delivered',   'Вручён (выкуп)',              6, true,  false, true),
    ('unavailable', 'Недоступен (нет товара)',     7, false, true,  true),
    ('canceled',    'Отменён',                     8, false, true,  true);

INSERT INTO core.dim_order_status
    (order_status, status_name_ru, stage_order, is_revenue, is_cancelled, is_final, is_documented)
SELECT DISTINCT o.order_status, 'не описан', 99, false, false, false, false
FROM stg.orders o
WHERE o.order_status IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM core.dim_order_status d WHERE d.order_status = o.order_status);

COMMENT ON TABLE  core.dim_order_status IS 'Статусы заказа с бизнес-флагами. Единственное место, где задано правило признания выручки';
COMMENT ON COLUMN core.dim_order_status.is_revenue   IS 'Заказ в этом статусе признаётся выручкой (выкуп). Сейчас только delivered';
COMMENT ON COLUMN core.dim_order_status.is_cancelled IS 'Заказ не состоялся: отмена или нет товара';
COMMENT ON COLUMN core.dim_order_status.is_final     IS 'Статус конечный, дальше не изменится';
COMMENT ON COLUMN core.dim_order_status.is_documented IS 'false — статус пришёл из данных, но не описан в справочнике (dq предупреждает)';

-- ---------------------------------------------------------------------
--  dim_payment_type — способы оплаты
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_payment_type (
    payment_type    text        PRIMARY KEY,
    payment_name_ru text        NOT NULL,
    is_defined      boolean     NOT NULL,
    is_documented   boolean     NOT NULL DEFAULT true
);

INSERT INTO core.dim_payment_type (payment_type, payment_name_ru, is_defined) VALUES
    ('credit_card', 'Кредитная карта (в т.ч. рассрочка)', true),
    ('boleto',      'Boleto (банковский счёт на оплату)',  true),
    ('voucher',     'Ваучер / промокод',                   true),
    ('debit_card',  'Дебетовая карта',                     true),
    ('not_defined', 'Не определён',                        false);

INSERT INTO core.dim_payment_type (payment_type, payment_name_ru, is_defined, is_documented)
SELECT DISTINCT p.payment_type, 'не описан', false, false
FROM stg.order_payments p
WHERE p.payment_type IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM core.dim_payment_type d WHERE d.payment_type = p.payment_type);

COMMENT ON TABLE core.dim_payment_type IS 'Способы оплаты. not_defined — отдельный член, а не NULL';

-- ---------------------------------------------------------------------
--  dim_category — категории товаров.
--  -1  неизвестно      — товар не найден в справочнике (сейчас не встречается)
--   0  sem_categoria   — у товара категория не заполнена (610 товаров)
--  Перевод: из справочника, иначе португальское название.
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_category (
    category_sk         integer     PRIMARY KEY,
    category_code       text        NOT NULL UNIQUE,
    category_name_en    text        NOT NULL,
    is_translated       boolean     NOT NULL,
    is_unlabeled        boolean     NOT NULL
);

INSERT INTO core.dim_category VALUES
    (-1, 'unknown',       'unknown',       false, true),
    ( 0, 'sem_categoria', 'no_category',   false, true);

INSERT INTO core.dim_category (category_sk, category_code, category_name_en, is_translated, is_unlabeled)
SELECT row_number() OVER (ORDER BY c.category_code),
       c.category_code,
       coalesce(t.category_name_en, c.category_code),
       t.category_name_en IS NOT NULL,
       false
FROM (
    SELECT category_code FROM stg.products WHERE category_code IS NOT NULL
    UNION
    SELECT category_code FROM stg.category_translation
) c
LEFT JOIN stg.category_translation t USING (category_code);

COMMENT ON TABLE  core.dim_category IS 'Категории: все из товаров и из справочника перевода. 0 = без категории, -1 = неизвестно';
COMMENT ON COLUMN core.dim_category.category_code    IS 'Натуральный ключ: название на португальском из источника';
COMMENT ON COLUMN core.dim_category.category_name_en IS 'Перевод; если перевода нет, португальское название';
COMMENT ON COLUMN core.dim_category.is_translated    IS 'false — перевода в справочнике не было (pc_gamer и portateis_cozinha…)';
COMMENT ON COLUMN core.dim_category.is_unlabeled     IS 'Служебный член: без категории или неизвестно';

-- ---------------------------------------------------------------------
--  dim_product — карточка товара
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_product (
    product_sk          integer     PRIMARY KEY,
    product_id          text        NOT NULL UNIQUE,
    category_sk         integer     NOT NULL REFERENCES core.dim_category,
    name_length         integer,
    description_length  integer,
    photos_qty          integer,
    weight_g            integer,
    length_cm           integer,
    height_cm           integer,
    width_cm            integer,
    volume_cm3          integer GENERATED ALWAYS AS (length_cm * height_cm * width_cm) STORED
);

INSERT INTO core.dim_product (product_sk, product_id, category_sk)
VALUES (-1, 'unknown', -1);

INSERT INTO core.dim_product
    (product_sk, product_id, category_sk, name_length, description_length,
     photos_qty, weight_g, length_cm, height_cm, width_cm)
SELECT row_number() OVER (ORDER BY p.product_id),
       p.product_id,
       CASE WHEN p.category_code IS NULL THEN 0 ELSE coalesce(c.category_sk, -1) END,
       p.name_length, p.description_length, p.photos_qty,
       p.weight_g, p.length_cm, p.height_cm, p.width_cm
FROM stg.products p
LEFT JOIN core.dim_category c ON c.category_code = p.category_code;

COMMENT ON TABLE  core.dim_product IS 'Товары (карточки). Цена — не атрибут товара, а позиции заказа: один товар продаётся по разным ценам';
COMMENT ON COLUMN core.dim_product.category_sk IS '0 — категория не заполнена в источнике';
COMMENT ON COLUMN core.dim_product.name_length IS 'В источнике колонка product_name_lenght (опечатка)';

-- ---------------------------------------------------------------------
--  dim_seller — продавцы
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_seller (
    seller_sk       integer     PRIMARY KEY,
    seller_id       text        NOT NULL UNIQUE,
    zip_prefix      text,
    city            text,
    city_raw        text,
    state_code      text     REFERENCES core.dim_state
);

INSERT INTO core.dim_seller (seller_sk, seller_id) VALUES (-1, 'unknown');

INSERT INTO core.dim_seller (seller_sk, seller_id, zip_prefix, city, city_raw, state_code)
SELECT row_number() OVER (ORDER BY seller_id),
       seller_id, zip_prefix, city, city_raw, state_code
FROM stg.sellers;

COMMENT ON TABLE  core.dim_seller IS 'Продавцы. Город нормализован, исходное написание — в city_raw';
COMMENT ON COLUMN core.dim_seller.city IS 'NULL, если в источнике вместо города email, цифры или код штата';

-- ---------------------------------------------------------------------
--  dim_customer — покупатель как человек (customer_unique_id).
--  customer_id в источнике выдаётся на каждый заказ заново, поэтому
--  ключом покупателя быть не может. Адрес на момент заказа хранится
--  в fact_order; здесь — последний известный адрес и когорта.
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_customer (
    customer_sk         integer     PRIMARY KEY,
    customer_unique_id  text        NOT NULL UNIQUE,
    zip_prefix          text,
    city                text,
    state_code          text     REFERENCES core.dim_state,
    first_order_ts      timestamp,
    cohort_month        date,
    addresses_count     integer     NOT NULL DEFAULT 0
);

INSERT INTO core.dim_customer (customer_sk, customer_unique_id) VALUES (-1, 'unknown');

WITH per_customer AS (
    SELECT c.customer_unique_id,
           min(o.purchase_ts) AS first_order_ts,
           count(DISTINCT concat_ws('|', c.zip_prefix, c.city, c.state_code)) AS addresses_count
    FROM stg.customers c
    LEFT JOIN stg.orders o USING (customer_id)
    WHERE c.customer_unique_id IS NOT NULL
    GROUP BY c.customer_unique_id
), last_address AS (
    SELECT DISTINCT ON (c.customer_unique_id)
           c.customer_unique_id, c.zip_prefix, c.city, c.state_code
    FROM stg.customers c
    LEFT JOIN stg.orders o USING (customer_id)
    WHERE c.customer_unique_id IS NOT NULL
    ORDER BY c.customer_unique_id, o.purchase_ts DESC NULLS LAST, c.customer_id
)
INSERT INTO core.dim_customer
    (customer_sk, customer_unique_id, zip_prefix, city, state_code,
     first_order_ts, cohort_month, addresses_count)
SELECT row_number() OVER (ORDER BY p.customer_unique_id),
       p.customer_unique_id, a.zip_prefix, a.city, a.state_code,
       p.first_order_ts, date_trunc('month', p.first_order_ts)::date, p.addresses_count
FROM per_customer p
JOIN last_address a USING (customer_unique_id);

COMMENT ON TABLE  core.dim_customer IS 'Покупатель-человек: customer_unique_id. Адрес — последний известный; адрес доставки конкретного заказа — в fact_order';
COMMENT ON COLUMN core.dim_customer.first_order_ts  IS 'Первый заказ в любом статусе';
COMMENT ON COLUMN core.dim_customer.cohort_month    IS 'Месяц первого заказа: когорта для удержания';
COMMENT ON COLUMN core.dim_customer.addresses_count IS 'Сколько разных адресов было у покупателя (>1 у 252 человек)';

-- Таблицы созданы в транзакции сборки: autovacuum их ещё не видит,
-- без явной статистики планировщик выбирает вложенные циклы вслепую.
ANALYZE core.dim_date, core.dim_state, core.dim_order_status, core.dim_payment_type,
        core.dim_category, core.dim_product, core.dim_seller, core.dim_customer;

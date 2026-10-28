-- =====================================================================
--  30. CORE: факты
--
--  fact_order       зерно: заказ. Накопительный снимок: все вехи
--                   жизненного цикла, длительности, суммы, флаги качества
--  fact_order_item  зерно: единица товара в заказе (order_id, order_item_id)
--  fact_payment     зерно: платёж (order_id, payment_sequential)
--  fact_review      зерно: отзыв на заказ (review_id, order_id)
--
--  Позиции и платежи агрегируются по заказу ПО ОТДЕЛЬНОСТИ и только потом
--  присоединяются к заказу. Прямой JOIN позиций с платежами размножает
--  строки (N позиций × M платежей) и завышает суммы.
-- =====================================================================

-- ---------------------------------------------------------------------
--  fact_order
-- ---------------------------------------------------------------------
CREATE TABLE core.fact_order (
    order_id                    text        PRIMARY KEY,
    customer_sk                 integer     NOT NULL,
    customer_id                 text,
    order_status                text        NOT NULL,
    purchase_date               date,

    -- вехи (местное время Сан-Паулу, без часового пояса — как в источнике)
    purchase_ts                 timestamp,
    approved_ts                 timestamp,
    delivered_carrier_ts        timestamp,
    delivered_customer_ts       timestamp,
    estimated_delivery_date     date,

    -- адрес доставки на момент заказа
    delivery_zip_prefix         text,
    delivery_city               text,
    delivery_state_code         text,

    -- состав заказа (из fact_order_item)
    units_count                 integer     NOT NULL DEFAULT 0,
    lines_count                 integer     NOT NULL DEFAULT 0,
    products_count              integer     NOT NULL DEFAULT 0,
    sellers_count               integer     NOT NULL DEFAULT 0,

    -- деньги
    items_amount                numeric(12,2) NOT NULL DEFAULT 0,
    freight_amount              numeric(12,2) NOT NULL DEFAULT 0,
    order_amount                numeric(12,2) GENERATED ALWAYS AS (items_amount + freight_amount) STORED,
    payments_count              integer     NOT NULL DEFAULT 0,
    payment_amount              numeric(12,2) NOT NULL DEFAULT 0,
    max_installments            integer,

    -- длительности в днях; NULL, если этап не случился или хронология этапа нарушена
    approval_hours              numeric(10,2),
    seller_handling_days        numeric(10,2),
    carrier_transit_days        numeric(10,2),
    delivery_days               numeric(10,2),
    delivery_delay_days         integer,
    is_delivered_late           boolean,

    -- последний отзыв (подробности — в fact_review)
    review_score                smallint,

    -- флаги качества данных
    has_items                   boolean     NOT NULL,
    has_payment                 boolean     NOT NULL,
    is_payment_mismatch         boolean     NOT NULL,
    is_chronology_broken        boolean     NOT NULL,
    is_delivered_without_date   boolean     NOT NULL,
    is_cancelled_with_delivery  boolean     NOT NULL
);

WITH item_totals AS (
    SELECT order_id,
           count(*)                                AS units_count,
           count(DISTINCT (product_id, seller_id)) AS lines_count,
           count(DISTINCT product_id)              AS products_count,
           count(DISTINCT seller_id)               AS sellers_count,
           sum(price)                              AS items_amount,
           sum(freight_value)                      AS freight_amount
    FROM stg.order_items
    GROUP BY order_id
), payment_totals AS (
    SELECT order_id,
           count(*)                  AS payments_count,
           sum(payment_value)        AS payment_amount,
           max(payment_installments) AS max_installments
    FROM stg.order_payments
    GROUP BY order_id
), last_review AS (
    SELECT DISTINCT ON (order_id) order_id, review_score
    FROM stg.order_reviews
    ORDER BY order_id, answer_ts DESC NULLS LAST, creation_ts DESC NULLS LAST, review_id
), base AS (
    SELECT o.*,
           c.customer_unique_id,
           c.zip_prefix AS delivery_zip_prefix,
           c.city       AS delivery_city,
           c.state_code AS delivery_state_code,
           -- хронология нарушена: вручён раньше передачи или передан раньше оформления
           coalesce(o.delivered_carrier_ts < o.purchase_ts, false)
             OR coalesce(o.delivered_customer_ts < o.delivered_carrier_ts, false)
             OR coalesce(o.delivered_customer_ts < o.purchase_ts, false) AS is_chronology_broken
    FROM stg.orders o
    LEFT JOIN stg.customers c USING (customer_id)
)
INSERT INTO core.fact_order (
    order_id, customer_sk, customer_id, order_status, purchase_date,
    purchase_ts, approved_ts, delivered_carrier_ts, delivered_customer_ts, estimated_delivery_date,
    delivery_zip_prefix, delivery_city, delivery_state_code,
    units_count, lines_count, products_count, sellers_count,
    items_amount, freight_amount, payments_count, payment_amount, max_installments,
    approval_hours, seller_handling_days, carrier_transit_days, delivery_days,
    delivery_delay_days, is_delivered_late, review_score,
    has_items, has_payment, is_payment_mismatch, is_chronology_broken,
    is_delivered_without_date, is_cancelled_with_delivery)
SELECT b.order_id,
       coalesce(dc.customer_sk, -1),
       b.customer_id,
       b.order_status,
       b.purchase_ts::date,
       b.purchase_ts, b.approved_ts, b.delivered_carrier_ts, b.delivered_customer_ts,
       b.estimated_delivery_date,
       b.delivery_zip_prefix, b.delivery_city, b.delivery_state_code,
       coalesce(i.units_count, 0), coalesce(i.lines_count, 0),
       coalesce(i.products_count, 0), coalesce(i.sellers_count, 0),
       coalesce(i.items_amount, 0), coalesce(i.freight_amount, 0),
       coalesce(p.payments_count, 0), coalesce(p.payment_amount, 0), p.max_installments,
       round(extract(epoch FROM b.approved_ts - b.purchase_ts) / 3600, 2),
       CASE WHEN b.delivered_carrier_ts >= b.purchase_ts
            THEN round(extract(epoch FROM b.delivered_carrier_ts - b.purchase_ts) / 86400, 2) END,
       CASE WHEN b.delivered_customer_ts >= b.delivered_carrier_ts
            THEN round(extract(epoch FROM b.delivered_customer_ts - b.delivered_carrier_ts) / 86400, 2) END,
       CASE WHEN b.delivered_customer_ts >= b.purchase_ts
            THEN round(extract(epoch FROM b.delivered_customer_ts - b.purchase_ts) / 86400, 2) END,
       b.delivered_customer_ts::date - b.estimated_delivery_date,
       b.delivered_customer_ts::date > b.estimated_delivery_date,
       r.review_score,
       i.order_id IS NOT NULL,
       p.order_id IS NOT NULL,
       i.order_id IS NOT NULL AND p.order_id IS NOT NULL
           AND abs(i.items_amount + i.freight_amount - p.payment_amount) > 0.01,
       b.is_chronology_broken,
       b.order_status = 'delivered' AND b.delivered_customer_ts IS NULL,
       ds.is_cancelled AND b.delivered_customer_ts IS NOT NULL
FROM base b
JOIN core.dim_order_status ds USING (order_status)
LEFT JOIN core.dim_customer dc USING (customer_unique_id)
LEFT JOIN item_totals    i USING (order_id)
LEFT JOIN payment_totals p USING (order_id)
LEFT JOIN last_review    r USING (order_id);

ANALYZE core.fact_order;

CREATE INDEX ON core.fact_order (purchase_date);
CREATE INDEX ON core.fact_order (customer_sk);
CREATE INDEX ON core.fact_order (order_status);

COMMENT ON TABLE  core.fact_order IS 'Заказ (накопительный снимок). Зерно: order_id. Все заказы, включая 775 без позиций';
COMMENT ON COLUMN core.fact_order.customer_sk         IS 'Покупатель-человек (customer_unique_id). Ключ для подсчёта покупателей и повторных покупок';
COMMENT ON COLUMN core.fact_order.customer_id         IS 'Идентификатор покупателя из источника: уникален для каждого заказа, для подсчёта покупателей не годится';
COMMENT ON COLUMN core.fact_order.purchase_date       IS 'Дата оформления: ключ к календарю, выручка признаётся по этой дате';
COMMENT ON COLUMN core.fact_order.delivery_state_code IS 'Штат доставки на момент заказа (адрес мог меняться)';
COMMENT ON COLUMN core.fact_order.units_count         IS 'Единиц товара = строк в fact_order_item';
COMMENT ON COLUMN core.fact_order.lines_count         IS 'Разных пар (товар, продавец): «строк» в корзине';
COMMENT ON COLUMN core.fact_order.items_amount        IS 'Сумма цен товаров без доставки';
COMMENT ON COLUMN core.fact_order.freight_amount      IS 'Сумма доставки по позициям';
COMMENT ON COLUMN core.fact_order.order_amount        IS 'Чек: товары + доставка';
COMMENT ON COLUMN core.fact_order.payment_amount      IS 'Фактически оплачено (сумма платежей). Может отличаться от чека: ваучеры, проценты рассрочки';
COMMENT ON COLUMN core.fact_order.approval_hours      IS 'Часы от оформления до подтверждения оплаты';
COMMENT ON COLUMN core.fact_order.seller_handling_days IS 'Дни от оформления до передачи в доставку; NULL при нарушенной хронологии';
COMMENT ON COLUMN core.fact_order.carrier_transit_days IS 'Дни от передачи в доставку до вручения; NULL при нарушенной хронологии';
COMMENT ON COLUMN core.fact_order.delivery_days       IS 'Дни от оформления до вручения';
COMMENT ON COLUMN core.fact_order.delivery_delay_days IS 'Дата вручения минус обещанная дата, в днях (>0 — опоздание)';
COMMENT ON COLUMN core.fact_order.is_delivered_late   IS 'Вручён позже обещанной даты; NULL, если не вручён';
COMMENT ON COLUMN core.fact_order.review_score        IS 'Оценка последнего отзыва по заказу';
COMMENT ON COLUMN core.fact_order.is_payment_mismatch IS 'Оплачено ≠ товары + доставка (больше 0.01)';
COMMENT ON COLUMN core.fact_order.is_chronology_broken IS 'Передан в доставку раньше оформления или вручён раньше передачи';
COMMENT ON COLUMN core.fact_order.is_delivered_without_date IS 'Статус delivered, но даты вручения нет';
COMMENT ON COLUMN core.fact_order.is_cancelled_with_delivery IS 'Статус отмены, но дата вручения есть';

-- ---------------------------------------------------------------------
--  fact_order_item — одна единица товара
-- ---------------------------------------------------------------------
CREATE TABLE core.fact_order_item (
    order_id                    text        NOT NULL,
    order_item_id               integer     NOT NULL,
    product_sk                  integer     NOT NULL,
    seller_sk                   integer     NOT NULL,
    customer_sk                 integer     NOT NULL,
    order_status                text        NOT NULL,
    purchase_date               date,
    shipping_limit_ts           timestamp,
    price                       numeric(12,2) NOT NULL,
    freight_value               numeric(12,2) NOT NULL,
    item_amount                 numeric(12,2) GENERATED ALWAYS AS (price + freight_value) STORED,
    is_shipped_late             boolean,
    is_shipping_limit_suspicious boolean    NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO core.fact_order_item (
    order_id, order_item_id, product_sk, seller_sk, customer_sk, order_status, purchase_date,
    shipping_limit_ts, price, freight_value, is_shipped_late, is_shipping_limit_suspicious)
SELECT i.order_id,
       i.order_item_id,
       coalesce(dp.product_sk, -1),
       coalesce(ds.seller_sk, -1),
       o.customer_sk,
       o.order_status,
       o.purchase_date,
       i.shipping_limit_ts,
       i.price,
       i.freight_value,
       o.delivered_carrier_ts > i.shipping_limit_ts,
       coalesce(i.shipping_limit_ts > o.purchase_ts + interval '1 year', false)
FROM stg.order_items i
JOIN core.fact_order o USING (order_id)
LEFT JOIN core.dim_product dp USING (product_id)
LEFT JOIN core.dim_seller  ds USING (seller_id);

CREATE INDEX ON core.fact_order_item (seller_sk);
CREATE INDEX ON core.fact_order_item (product_sk);
CREATE INDEX ON core.fact_order_item (purchase_date);

COMMENT ON TABLE  core.fact_order_item IS 'Позиция заказа. Зерно: одна единица товара (order_id, order_item_id). Два одинаковых товара в заказе — две строки';
COMMENT ON COLUMN core.fact_order_item.order_item_id IS 'Порядковый номер единицы внутри заказа (1..21), не идентификатор';
COMMENT ON COLUMN core.fact_order_item.customer_sk   IS 'Копия из fact_order для срезов без лишнего JOIN';
COMMENT ON COLUMN core.fact_order_item.order_status  IS 'Копия из fact_order: модель пересобирается целиком, расхождение невозможно';
COMMENT ON COLUMN core.fact_order_item.price         IS 'Цена единицы у этого продавца в этом заказе';
COMMENT ON COLUMN core.fact_order_item.freight_value IS 'Доставка, приходящаяся на эту единицу';
COMMENT ON COLUMN core.fact_order_item.is_shipped_late IS 'Передан в доставку позже крайнего срока отгрузки (SLA продавца); NULL, если не передан';
COMMENT ON COLUMN core.fact_order_item.is_shipping_limit_suspicious IS 'Срок отгрузки больше чем через год после заказа (4 позиции с датами 2020 года)';

-- ---------------------------------------------------------------------
--  fact_payment
-- ---------------------------------------------------------------------
CREATE TABLE core.fact_payment (
    order_id                text        NOT NULL,
    payment_sequential      integer     NOT NULL,
    payment_type            text        NOT NULL,
    purchase_date           date,
    payment_installments    integer,
    payment_value           numeric(12,2) NOT NULL,
    is_zero_value           boolean     NOT NULL,
    is_zero_installments    boolean     NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

INSERT INTO core.fact_payment (
    order_id, payment_sequential, payment_type, purchase_date, payment_installments,
    payment_value, is_zero_value, is_zero_installments)
SELECT p.order_id,
       p.payment_sequential,
       coalesce(p.payment_type, 'not_defined'),
       o.purchase_date,
       p.payment_installments,
       p.payment_value,
       p.payment_value = 0,
       coalesce(p.payment_installments = 0, false)
FROM stg.order_payments p
JOIN core.fact_order o USING (order_id);

CREATE INDEX ON core.fact_payment (payment_type);

COMMENT ON TABLE  core.fact_payment IS 'Платёж. Зерно: (order_id, payment_sequential). Нумерация не плотная: считать платежи через count(*)';
COMMENT ON COLUMN core.fact_payment.payment_installments IS 'Число частей рассрочки; 0 у двух платежей — ошибка источника, флаг is_zero_installments';

-- ---------------------------------------------------------------------
--  fact_review
-- ---------------------------------------------------------------------
CREATE TABLE core.fact_review (
    review_id               text        NOT NULL,
    order_id                text        NOT NULL,
    review_score            smallint    NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title           text,
    comment_message         text,
    has_comment             boolean     NOT NULL,
    creation_date           date,
    answer_ts               timestamp,
    answer_hours            numeric(10,2),
    is_latest_for_order     boolean     NOT NULL,
    PRIMARY KEY (review_id, order_id)
);

INSERT INTO core.fact_review (
    review_id, order_id, review_score, comment_title, comment_message, has_comment,
    creation_date, answer_ts, answer_hours, is_latest_for_order)
SELECT r.review_id,
       r.order_id,
       r.review_score,
       r.comment_title,
       r.comment_message,
       r.comment_title IS NOT NULL OR r.comment_message IS NOT NULL,
       r.creation_ts::date,
       r.answer_ts,
       round(extract(epoch FROM r.answer_ts - r.creation_ts) / 3600, 2),
       row_number() OVER (PARTITION BY r.order_id
                          ORDER BY r.answer_ts DESC NULLS LAST, r.creation_ts DESC NULLS LAST, r.review_id) = 1
FROM stg.order_reviews r
JOIN core.fact_order o USING (order_id);

CREATE INDEX ON core.fact_review (order_id);

COMMENT ON TABLE  core.fact_review IS 'Отзыв на заказ. Зерно: (review_id, order_id): 789 review_id относятся к нескольким заказам, у 547 заказов несколько отзывов';
COMMENT ON COLUMN core.fact_review.is_latest_for_order IS 'Последний отзыв по заказу (по времени ответа). Для оценки заказа брать только его';
COMMENT ON COLUMN core.fact_review.answer_hours IS 'Часы от отправки анкеты до ответа покупателя';

-- ---------------------------------------------------------------------
--  Внешние ключи добавляются после загрузки: Postgres проверяет каждый
--  ключ одним соединением, а не триггером на каждую строку
--  (так сборка фактов идёт секунды, а не минуту). Целостность та же:
--  при нарушении ALTER TABLE падает, и транзакция сборки откатывается.
-- ---------------------------------------------------------------------
ALTER TABLE core.fact_order ADD FOREIGN KEY (customer_sk) REFERENCES core.dim_customer;
ALTER TABLE core.fact_order ADD FOREIGN KEY (order_status) REFERENCES core.dim_order_status;
ALTER TABLE core.fact_order ADD FOREIGN KEY (purchase_date) REFERENCES core.dim_date;
ALTER TABLE core.fact_order ADD FOREIGN KEY (delivery_state_code) REFERENCES core.dim_state;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (order_id) REFERENCES core.fact_order;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (product_sk) REFERENCES core.dim_product;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (seller_sk) REFERENCES core.dim_seller;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (customer_sk) REFERENCES core.dim_customer;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (order_status) REFERENCES core.dim_order_status;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (purchase_date) REFERENCES core.dim_date;
ALTER TABLE core.fact_payment ADD FOREIGN KEY (order_id) REFERENCES core.fact_order;
ALTER TABLE core.fact_payment ADD FOREIGN KEY (payment_type) REFERENCES core.dim_payment_type;
ALTER TABLE core.fact_payment ADD FOREIGN KEY (purchase_date) REFERENCES core.dim_date;
ALTER TABLE core.fact_review ADD FOREIGN KEY (order_id) REFERENCES core.fact_order;

ANALYZE core.fact_order_item, core.fact_payment, core.fact_review;

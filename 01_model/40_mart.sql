-- =====================================================================
--  40. MART: семантический слой поверх core
--
--  mart.v_delivery         витрина дашборда «Обещание доставки»:
--                          один выкупленный заказ = одна строка
--  mart.agg_delivery_hist  агрегат месяц × штат × дней доставки.
--                          Хранит гистограмму, а не медиану: медианы не
--                          складываются, а из гистограммы медиана любого
--                          среза считается точно
--  mart.metric_catalog     каталог показателей: формула, уровень, источник,
--                          аддитивность. Одна формула для всех отчётов
-- =====================================================================

-- ---------------------------------------------------------------------
--  v_delivery
--  Входят выкупленные заказы (is_revenue) с датой вручения и без
--  нарушенной хронологии, оформленные до сентября 2018. Исключённые
--  строки не удаляются из core, а видны по флагам fact_order.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_delivery AS
SELECT o.order_id,
       o.customer_sk,
       o.delivery_state_code                                   AS customer_state,
       d.month_start                                           AS purchase_month,
       o.purchase_ts,
       o.items_amount,
       o.order_amount,
       o.delivered_customer_ts::date - o.purchase_date         AS delivery_days,
       o.estimated_delivery_date - o.purchase_date             AS promised_days,
       o.delivery_delay_days                                   AS delay_days,
       NOT o.is_delivered_late                                 AS is_on_time,
       o.approval_hours,
       o.seller_handling_days,
       o.carrier_transit_days,
       o.review_score
FROM core.fact_order o
JOIN core.dim_order_status s ON s.order_status = o.order_status
JOIN core.dim_date d         ON d.calendar_date = o.purchase_date
WHERE s.is_revenue
  AND o.delivered_customer_ts IS NOT NULL
  AND NOT o.is_chronology_broken
  AND o.purchase_date < DATE '2018-09-01';

COMMENT ON VIEW mart.v_delivery IS
    'Дашборд «Обещание доставки». Зерно: выкупленный заказ с датой вручения и корректной хронологией';
COMMENT ON COLUMN mart.v_delivery.delivery_days IS 'Дней от оформления до вручения (по датам)';
COMMENT ON COLUMN mart.v_delivery.promised_days IS 'Обещанный срок: дней от оформления до обещанной даты';
COMMENT ON COLUMN mart.v_delivery.delay_days    IS 'Дата вручения минус обещанная дата: < 0 раньше срока, > 0 опоздание';
COMMENT ON COLUMN mart.v_delivery.is_on_time    IS 'Вручён не позже обещанной даты';

-- ---------------------------------------------------------------------
--  agg_delivery_hist
-- ---------------------------------------------------------------------
CREATE TABLE mart.agg_delivery_hist AS
SELECT purchase_month,
       customer_state,
       delivery_days,
       count(*)                                  AS orders,
       count(*) FILTER (WHERE is_on_time)        AS on_time_orders,
       sum(promised_days)                        AS promised_days_sum,
       sum(review_score)                         AS review_score_sum,
       count(review_score)                       AS review_count,
       sum(items_amount)                         AS items_amount
FROM mart.v_delivery
GROUP BY purchase_month, customer_state, delivery_days;

ALTER TABLE mart.agg_delivery_hist ADD PRIMARY KEY (purchase_month, customer_state, delivery_days);

COMMENT ON TABLE mart.agg_delivery_hist IS
    'Агрегат месяц × штат × дней доставки. Все колонки аддитивны (числа и суммы): доли, средние и медианы любого среза считаются из них точно';

-- ---------------------------------------------------------------------
--  metric_catalog
-- ---------------------------------------------------------------------
CREATE TABLE mart.metric_catalog (
    metric_code     text PRIMARY KEY,
    metric_name_ru  text NOT NULL,
    formula         text NOT NULL,
    grain           text NOT NULL,
    source          text NOT NULL,
    additivity      text NOT NULL CHECK (additivity IN ('аддитивный', 'полуаддитивный', 'неаддитивный')),
    how_to_slice    text NOT NULL
);

INSERT INTO mart.metric_catalog VALUES
('revenue',            'Выручка (выкуп)',              'sum(price) по позициям выкупленных заказов, без доставки',
                       'единица товара', 'core.fact_order_item ⋈ dim_order_status(is_revenue)', 'аддитивный', 'Складывается по любым срезам'),
('orders_delivered',   'Выкупленные заказы',           'count(order_id), статус is_revenue',
                       'заказ', 'core.fact_order', 'аддитивный', 'Складывается по любым срезам'),
('avg_order_value',    'Средний чек',                  'sum(order_amount) / count(order_id) по выкупленным заказам',
                       'заказ', 'core.fact_order', 'неаддитивный', 'Хранить сумму и число заказов, делить в конце'),
('customers',          'Покупатели',                   'count(DISTINCT customer_sk)',
                       'покупатель', 'core.fact_order', 'неаддитивный', 'Один человек покупает в разных месяцах: пересчитывать по customer_sk'),
('repeat_rate',        'Доля повторных покупателей',   'покупатели с 2+ заказами / все покупатели',
                       'покупатель', 'core.fact_order', 'неаддитивный', 'Пересчитывать из числителя и знаменателя'),
('on_time_rate',       'Доля доставленных вовремя',    'count(is_on_time) / count(*)',
                       'заказ', 'mart.v_delivery', 'неаддитивный', 'Хранить числитель и знаменатель (agg_delivery_hist)'),
('median_delivery',    'Медиана срока доставки',       'percentile_cont(0.5) по delivery_days',
                       'заказ', 'mart.v_delivery', 'неаддитивный', 'Хранить гистограмму дней (agg_delivery_hist)'),
('promised_days',      'Обещанный срок',               'avg(estimated_delivery_date − purchase_date)',
                       'заказ', 'mart.v_delivery', 'неаддитивный', 'Через сумму и число (promised_days_sum, orders)'),
('promise_buffer',     'Запас обещания',               'avg(−delay_days): на сколько дней раньше обещанного',
                       'заказ', 'mart.v_delivery', 'неаддитивный', 'Через сумму и число'),
('stage_duration',     'Длительность этапа',           'avg(approval_hours), avg(seller_handling_days), avg(carrier_transit_days)',
                       'заказ', 'core.fact_order', 'неаддитивный', 'Через сумму и число; заказы с нарушенной хронологией исключены (NULL)'),
('seller_late_rate',   'Опоздание отгрузки продавцом', 'доля единиц, где delivered_carrier_ts > shipping_limit_ts',
                       'единица товара', 'core.fact_order_item.is_shipped_late', 'неаддитивный', 'Считать по единицам: у продавцов одного заказа разные сроки'),
('avg_review_score',   'Средняя оценка',               'avg(review_score) по последнему отзыву заказа',
                       'заказ', 'core.fact_review(is_latest_for_order)', 'неаддитивный', 'Через сумму и число оценок'),
('bad_review_rate',    'Доля оценок 1–2',              'отзывы с оценкой ≤ 2 / все отзывы',
                       'заказ', 'core.fact_review(is_latest_for_order)', 'неаддитивный', 'Из числителя и знаменателя'),
('late_revenue',       'Выручка опоздавших заказов',   'sum(items_amount) по заказам с is_on_time = false',
                       'заказ', 'mart.v_delivery', 'аддитивный', 'Складывается по любым срезам');

COMMENT ON TABLE mart.metric_catalog IS 'Каталог показателей: одна формула на показатель, уровень расчёта, источник и правило агрегации по срезам';

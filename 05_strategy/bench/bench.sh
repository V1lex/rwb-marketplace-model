#!/usr/bin/env bash
# =====================================================================
#  Нагрузочный стенд: во сколько раз можно вырасти на PostgreSQL.
#
#  Создаёт рядом с рабочей базу bench, копирует в неё raw и размножает
#  заказы в N раз: новые id с суффиксом _k, те же даты — значит, в N раз
#  больше заказов в месяц. Каталог (товары, продавцы, категории) остаётся
#  прежним: растёт поток заказов, а не ассортимент. Затем запускает ту же
#  сборку 01_model/*.sql и замеряет типовые запросы (второй прогон, время
#  на сервере через \timing, без запуска psql).
#
#  Запуск из корня проекта:  bash 05_strategy/bench/bench.sh 10
#  Результат дописывается в 05_strategy/bench/results.csv
# =====================================================================
set -euo pipefail

N=${1:?укажите множитель, например 10}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT=05_strategy/bench/results.csv
PSQL="bash scripts/psql.sh -q"

echo "==> bench ×$N: копирую raw в базу bench"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS bench" -c "CREATE DATABASE bench"
$PSQL -d bench -c "CREATE SCHEMA raw"
bash scripts/psql.sh -q -d bench < scripts/init/02_raw_ddl.sql 2>/dev/null

# Переносим raw как есть: COPY в stdout из рабочей базы → COPY из stdin в bench
for t in orders order_items order_payments order_reviews products sellers customers product_category_translation; do
  cols=$($PSQL -tA -c "SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
                        FROM information_schema.columns
                        WHERE table_schema = 'raw' AND table_name = '$t' AND column_name NOT LIKE '\_%'")
  $PSQL -c "COPY (SELECT $cols FROM raw.$t) TO STDOUT" \
    | $PSQL -d bench -c "COPY raw.$t ($cols) FROM STDIN"
done

echo "==> размножаю заказы ×$N"
$PSQL -d bench <<SQL
SET max_parallel_workers_per_gather = 0;
CREATE TEMP TABLE k AS SELECT generate_series(2, $N) AS k;
INSERT INTO raw.orders (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
                        order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date)
SELECT order_id || '_' || k, customer_id || '_' || k, order_status, order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
FROM raw.orders, k;
INSERT INTO raw.order_items (order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value)
SELECT order_id || '_' || k, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
FROM raw.order_items, k;
INSERT INTO raw.order_payments (order_id, payment_sequential, payment_type, payment_installments, payment_value)
SELECT order_id || '_' || k, payment_sequential, payment_type, payment_installments, payment_value
FROM raw.order_payments, k;
INSERT INTO raw.order_reviews (review_id, order_id, review_score, review_comment_title, review_comment_message,
                               review_creation_date, review_answer_timestamp)
SELECT review_id || '_' || k, order_id || '_' || k, review_score, review_comment_title, review_comment_message,
       review_creation_date, review_answer_timestamp
FROM raw.order_reviews, k;
INSERT INTO raw.customers (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
SELECT customer_id || '_' || k, customer_unique_id || '_' || k, customer_zip_code_prefix, customer_city, customer_state
FROM raw.customers, k;
ANALYZE;
SQL
raw_rows=$($PSQL -d bench -tA -c "SELECT (SELECT count(*) FROM raw.orders) + (SELECT count(*) FROM raw.order_items)
  + (SELECT count(*) FROM raw.order_payments) + (SELECT count(*) FROM raw.order_reviews) + (SELECT count(*) FROM raw.customers)
  + (SELECT count(*) FROM raw.products) + (SELECT count(*) FROM raw.sellers) + (SELECT count(*) FROM raw.product_category_translation)")

echo "==> сборка модели ($raw_rows строк в raw)"
started=$(date +%s)
PGDATABASE=bench bash scripts/build_model.sh >/dev/null
build_s=$(( $(date +%s) - started ))

core_mb=$($PSQL -d bench -tA -c "SELECT round(sum(pg_total_relation_size(c.oid)) / 1024.0 / 1024)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'core' AND c.relkind = 'r'")
# Средний месяц 2018 года (январь–август): темп, на котором площадка работает сейчас
orders_month=$($PSQL -d bench -tA -c "SELECT round(count(*) / 8.0) FROM core.fact_order WHERE purchase_date BETWEEN '2018-01-01' AND '2018-08-31'")

# Время запроса на сервере: прогрев, затем замер второго прогона
q() {
  { echo "SET max_parallel_workers_per_gather = 0;"; echo "$1;"; echo '\timing on'; echo "$1;"; } \
    | $PSQL -d bench 2>&1 | grep -E '^(Время|Time):' | tail -1 | sed -E 's/^[^:]+: ([0-9]+)[.,].*/\1/'
}
q1=$(q "SELECT d.month_start, sum(o.items_amount) FILTER (WHERE s.is_revenue) FROM core.dim_date d
        LEFT JOIN core.fact_order o ON o.purchase_date = d.calendar_date LEFT JOIN core.dim_order_status s USING (order_status)
        WHERE d.calendar_date BETWEEN '2016-09-01' AND '2018-08-31' GROUP BY 1")
q2=$(q "SELECT i.seller_sk, sum(i.price) r FROM core.fact_order_item i JOIN core.dim_order_status s USING (order_status)
        WHERE s.is_revenue GROUP BY 1 ORDER BY r DESC LIMIT 10")
q4=$(q "SELECT count(*), count(*) FILTER (WHERE n > 1) FROM (SELECT customer_sk, count(*) n FROM core.fact_order GROUP BY 1) x")
qd=$(q "SELECT customer_state, avg(is_on_time::int), percentile_cont(0.5) WITHIN GROUP (ORDER BY delivery_days)
        FROM mart.v_delivery GROUP BY 1")
qh=$(q "SELECT customer_state, sum(on_time_orders)::numeric / sum(orders),
               min(delivery_days) FILTER (WHERE running >= total / 2.0)
        FROM (SELECT customer_state, delivery_days, orders, on_time_orders,
                     sum(orders) OVER (PARTITION BY customer_state ORDER BY delivery_days) running,
                     sum(orders) OVER (PARTITION BY customer_state) total
              FROM (SELECT customer_state, delivery_days, sum(orders) orders, sum(on_time_orders) on_time_orders
                    FROM mart.agg_delivery_hist GROUP BY 1, 2) h) x GROUP BY 1")
qp=$(q "SELECT * FROM core.fact_order WHERE order_id = (SELECT order_id FROM core.fact_order OFFSET 777 LIMIT 1)")

[ -f "$OUT" ] || echo "scale,orders_month,raw_rows,core_mb,build_s,q1_month_ms,q2_sellers_ms,q4_customers_ms,dash_state_fact_ms,dash_state_hist_ms,point_lookup_ms" > "$OUT"
echo "$N,$orders_month,$raw_rows,$core_mb,$build_s,$q1,$q2,$q4,$qd,$qh,$qp" | tee -a "$OUT"

$PSQL -d postgres -c "DROP DATABASE bench"

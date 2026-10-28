-- Контрольные цифры блока А из docs/task/tasks.md.
-- Раннер (scripts/run_answers.sh) создаёт временные представления q01..q05
-- ровно из сданных запросов, поэтому проверяется тот же код, что лежит в ответе.
SELECT * FROM (VALUES
    ('Q1: строк',                     24::numeric,  (SELECT count(*) FROM q01)::numeric),
    ('Q1: месяцев с нулевой выручкой', 1,           (SELECT count(*) FROM q01 WHERE revenue = 0)),
    ('Q1: итого выручка',             13221498.11,  (SELECT sum(revenue) FROM q01)),
    ('Q2: строк',                     10,           (SELECT count(*) FROM q02)),
    ('Q2: выручка первого продавца',  226987.93,    (SELECT max(revenue) FROM q02)),
    ('Q3: средний чек',               159.88,       (SELECT avg_order_value FROM q03)),
    ('Q4: покупателей',               96096,        (SELECT customers FROM q04)),
    ('Q4: доля вернувшихся, %',       3.12,         (SELECT returned_pct FROM q04)),
    ('Q5: категорий',                 74,           (SELECT count(*) FROM q05)),
    ('Q5: выручка крупнейшей',        1233131.72,   (SELECT max(revenue) FROM q05)),
    ('Q5: сумма по категориям',       13221498.11,  (SELECT sum(revenue) FROM q05)),
    ('Q5: сумма долей, %',            100,          (SELECT round(sum(share_pct)) FROM q05))
) AS t(check_name, expected, actual);

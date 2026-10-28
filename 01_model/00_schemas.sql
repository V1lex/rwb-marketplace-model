-- =====================================================================
--  00. Схемы
--
--  Сборка полная и атомарная: все файлы 01_model/*.sql выполняются
--  одной транзакцией (см. scripts/build_model.sh). Если упадёт любой шаг
--  или не пройдёт критическая сверка в 90_dq.sql, транзакция откатится
--  и в базе останется предыдущая рабочая версия модели.
--
--  raw  — организаторы, только читаем
--  stg  — ODS: типизированные и очищенные копии raw, дедупликация
--  core — модель: измерения и факты, физические таблицы
--  mart — семантический слой: каталог метрик и витрины поверх core
--  dq   — результаты сверок последней сборки
-- =====================================================================

-- В контейнере /dev/shm = 64 МБ, параллельный hash join на нём падает
-- с «could not resize shared memory segment». На наших объёмах не нужен.
SET max_parallel_workers_per_gather = 0;

DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS dq   CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
DROP SCHEMA IF EXISTS stg  CASCADE;

CREATE SCHEMA stg;
CREATE SCHEMA core;
CREATE SCHEMA mart;
CREATE SCHEMA dq;

COMMENT ON SCHEMA stg  IS 'ODS: типизированные и очищенные копии raw. Trim, нормализация, дедупликация по натуральному ключу';
COMMENT ON SCHEMA core IS 'Модель Capibara: звезда (dim_*, fact_*). Физические таблицы, после сборки не зависят от raw';
COMMENT ON SCHEMA mart IS 'Семантический слой: каталог метрик и витрины для аналитиков и дашбордов, строится только из core';
COMMENT ON SCHEMA dq   IS 'Качество данных: результаты сверок raw ↔ core последней сборки';

#!/usr/bin/env bash
# =====================================================================
#  Выполняет запросы-ответы из 02_answers/block_*/q*.sql:
#   1. сохраняет результат каждого в results/<имя>.csv;
#   2. если в блоке есть checks.sql — создаёт из каждого запроса временное
#      представление (q01, q02, …) и сверяет контрольные цифры.
#  Любое расхождение — ненулевой код выхода.
#
#  Запуск из корня проекта:  bash scripts/run_answers.sh   (или make answers)
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0
for block in 02_answers/block_*/; do
  queries=$(ls "$block"q*.sql 2>/dev/null || true)
  [ -n "$queries" ] || continue
  echo "==> $block"
  mkdir -p "$block/results"

  for q in $queries; do
    name=$(basename "$q" .sql)
    { echo "SET max_parallel_workers_per_gather = 0;"; cat "$q"; echo ";"; } \
      | bash scripts/psql.sh -q --csv > "$block/results/$name.csv"
    echo "    $name: $(( $(wc -l < "$block/results/$name.csv") - 1 )) строк → results/$name.csv"
  done

  if [ -f "$block/checks.sql" ]; then
    report=$({
      echo "SET max_parallel_workers_per_gather = 0;"
      for q in $queries; do
        view=$(basename "$q" | cut -d_ -f1)
        echo "CREATE TEMP VIEW $view AS"
        sed -e 's/;[[:space:]]*$//' "$q"
        echo ";"
      done
      echo "SELECT check_name AS проверка, expected AS ожидали, actual AS получили,"
      echo "       CASE WHEN expected = actual THEN 'ок' ELSE 'РАСХОЖДЕНИЕ' END AS итог"
      echo "FROM ("
      sed -e 's/;[[:space:]]*$//' "$block/checks.sql"
      echo ") c;"
    } | bash scripts/psql.sh -q -P pager=off)
    echo "$report"
    if echo "$report" | grep -q "РАСХОЖДЕНИЕ"; then status=1; fi
  fi
done

if [ "$status" -ne 0 ]; then
  echo "ОШИБКА: контрольные цифры не сошлись"; exit 1
fi
echo "Все контрольные цифры сошлись."

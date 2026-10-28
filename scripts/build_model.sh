#!/usr/bin/env bash
# =====================================================================
#  Сборка модели из raw с нуля: все файлы 01_model/*.sql по порядку
#  имён, одной транзакцией. Ошибка в любом файле или проваленная
#  самопроверка уровня error откатывает всё — в базе остаётся прежняя
#  рабочая версия модели.
#
#  Запуск из корня проекта:  bash scripts/build_model.sh   (или make build)
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

started=$(date +%s)
echo "==> Сборка модели: $(ls 01_model/*.sql | tr '\n' ' ')"

{
  echo "SET client_min_messages = warning;"
  for f in 01_model/*.sql; do
    echo "\\echo '    $f'"
    cat "$f"
    echo
  done
} | bash scripts/psql.sh -q --single-transaction

echo "==> Готово за $(( $(date +%s) - started )) с"
echo
bash scripts/psql.sh -q -P pager=off -c "
SELECT check_code AS код, severity AS уровень, description AS проверка,
       expected AS ожидали, actual AS получили,
       CASE WHEN passed THEN 'ок' ELSE 'ВНИМАНИЕ' END AS итог
FROM dq.check_result ORDER BY check_code;"

# Capibara: сборка модели одной командой.
#   make all      окружение + модель + проверки + ответы (с чистого листа)
#   make build    пересобрать модель из raw (core, stg, mart, dq)
#   make dq       показать результаты самопроверок последней сборки
#   make answers  выполнить запросы-ответы, сохранить результаты, сверить контрольные цифры
#
# Подключение по умолчанию — база из docker-compose.yml (localhost:5432, hack/hack).
# Другой порт:  make build PGPORT=5433

export PGPORT ?= 5432

.PHONY: all setup build dq answers

all: setup build answers

setup:
	bash scripts/setup.sh

build:
	bash scripts/build_model.sh

dq:
	bash scripts/psql.sh -P pager=off -c "SELECT * FROM dq.check_result ORDER BY check_code"

answers:
	bash scripts/run_answers.sh

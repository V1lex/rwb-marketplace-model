# Capibara: модель данных маркетплейса

Решение кейса RWB-TECH HACK «Модель маркетплейса: от корзины до выкупа».
Данные: Olist, 8 CSV, 550 759 строк, сентябрь 2016 — октябрь 2018.

## Что где сдаётся

| # | Артефакт | Папка |
|---|---|---|
| 1 | Схема и код: сборка модели из `raw` с нуля | [`01_model/`](01_model/) |
| 2 | Ответы на вопросы (блок А и блок Б) | [`02_answers/`](02_answers/) |
| 3 | Записка о решениях (≤ ½ страницы) | [`03_decision_note/`](03_decision_note/) |
| 4 | Концепция дашборда | [`04_dashboard_concept/`](04_dashboard_concept/) |
| 5 | Стратегия развития | [`05_strategy/`](05_strategy/) |
| 6 | Использование ИИ | [`06_ai_usage/`](06_ai_usage/) |

Вспомогательное: [`docs/00_requirements.md`](docs/00_requirements.md) — разбор требований,
[`docs/01_data_profile.md`](docs/01_data_profile.md) — профилирование данных,
[`docs/task/`](docs/task/) — копия задания организаторов.

## Окружение

`docker-compose.yml` и `scripts/` взяты из репозитория организаторов без изменений
([hackathon-students](https://github.com/daniilivanovp-droid/hackathon-students)).

```bash
make all        # всё с чистого листа: окружение, модель, проверки, ответы
```

По шагам:

```bash
make setup      # PostgreSQL 16 в Docker + загрузка raw (550 759 строк) — скрипт организаторов
make build      # сборка модели из raw одной транзакцией + 39 самопроверок
make dq         # результаты самопроверок
make answers    # ответы на вопросы + сверка с контрольными цифрами
```

Если локально нет `psql`, скрипты выполняют его внутри контейнера.
Если порт 5432 занят: поменять проброс в `docker-compose.yml`
(так советуют организаторы) и запускать `make build PGPORT=5433`.

Подключение: `postgresql://hack:hack@localhost:5432/marketplace`.

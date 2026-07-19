# Сценарии эмулятора клиента `kkt_client_emulator.py`

HTTP-клиент для Delphi KKT-сервера (`kktserverindy`).

**Запуск:** `python kkt_client_emulator.py <команда> [опции]`

**Общие параметры** (для всех команд):

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `--host` | `127.0.0.1` | Хост сервера |
| `--port` | `2580` | Порт HTTP-сервера |
| `--password` | `30` | Пароль ККТ (для POST-команд) |
| `--timeout` | `180` | Таймаут HTTP-запроса, сек |

Перед запуском: стартовать `kktserverindy` и нажать «Старт».

---

## Команды (одиночные сценарии)

### `health`

**Endpoint:** `GET /health`

Быстрая проверка, что HTTP-сервис запущен и отвечает (без обращения к ККТ, в отличие от `/info`).

```bash
python kkt_client_emulator.py health
```

Ожидаемый ответ: `result=1`, `status=up`, `service=kktserverindy`, `version=...`.

---

## `info`

**Endpoint:** `GET /info`

Информация о ККТ: серийный номер, ИНН, номер ФН, статус подключения.

```bash
python kkt_client_emulator.py info
```

---

### `print-check`

**Endpoint:** `POST /print-check`

Печать тестового чека или чека из JSON-файла.

| Параметр | Описание |
|----------|----------|
| `--json` | Путь к файлу чека (если не указан — встроенный тестовый чек) |
| `--with-marking` | Добавить маркированную позицию (`mark` в base64) |
| `--mark-accepted` | Для марки: `markAccepted=true` (марка уже проверена через `/check-marks`) |
| `--sell-return` | Чек возврата: `type=sellReturn` |

```bash
python kkt_client_emulator.py print-check
python kkt_client_emulator.py print-check --with-marking
python kkt_client_emulator.py print-check --with-marking --mark-accepted
python kkt_client_emulator.py print-check --sell-return
python kkt_client_emulator.py print-check --json sample-json-check.json
```

---

### `check-marks`

**Endpoint:** `POST /check-marks` (+ при `--async`: `GET /check-marks/status`)

Проверка одной или нескольких марок на ККТ.

| Параметр | Описание |
|----------|----------|
| `--mark` | Марка в открытом виде (кодируется в base64 автоматически) |
| `--mark-b64` | Марка уже в base64 |
| `--sell-return` | Возврат: `type=sellReturn` (по умолчанию `sell`) |
| `--async` | Асинхронный режим: сразу `taskId`, результат — через status |
| `--cashier` | Имя кассира при автоматическом открытии смены |
| `--wait` | Таймаут ожидания async-задачи, сек (по умолчанию `180`) |

```bash
python kkt_client_emulator.py check-marks
python kkt_client_emulator.py check-marks --mark "010460406000301021N4N57RDCUDVTL"
python kkt_client_emulator.py check-marks --async
python kkt_client_emulator.py check-marks --sell-return --cashier "Иванов"
```

---

### `check-marks-status`

**Endpoint:** `GET /check-marks/status?taskId=...`

Статус асинхронной проверки марки.

```bash
python kkt_client_emulator.py check-marks-status <taskId>
```

---

### `close-shift`

**Endpoint:** `POST /close-shift`

Закрытие смены (Z-отчёт с гашением).

```bash
python kkt_client_emulator.py close-shift
python kkt_client_emulator.py close-shift --password 30
```

---

### `x-report`

**Endpoint:** `POST /x-report`

X-отчёт без гашения.

```bash
python kkt_client_emulator.py x-report
```

---

### `cancel-check`

**Endpoint:** `POST /cancel-check`

Отмена открытого чека на ККТ.

```bash
python kkt_client_emulator.py cancel-check
```

---

### `disconnect`

**Endpoint:** `POST /disconnect`

Отключение от ККТ (разрыв COM-соединения).

```bash
python kkt_client_emulator.py disconnect
```

---

## Составной сценарий: `smoke`

Последовательный прогон основных endpoints в одной сессии:

1. `GET /health`
2. `GET /info`
2. `POST /print-check`
3. `POST /x-report`
4. `POST /cancel-check`
5. `POST /close-shift`
6. `POST /disconnect`

| Параметр | Описание |
|----------|----------|
| `--with-marking` | Печатать чек с маркированной позицией |

```bash
python kkt_client_emulator.py smoke
python kkt_client_emulator.py smoke --with-marking
```

---

## Тест очереди команд: `queue-test`

Проверка сериализации обращений к ККТ: async HTTP отвечает быстро, но работа с кассой идёт строго по очереди.

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `--scenario` | `all` | Сценарий: `all`, `sync-chain`, `async-burst`, `mixed` |
| `--count` | `3` | Число повторов (смысл зависит от сценария) |
| `--mark` | тестовая КМ | Марка для проверки (кодируется в base64) |
| `--wait` | `180` | Таймаут ожидания async-задач, сек |

```bash
python kkt_client_emulator.py queue-test
python kkt_client_emulator.py queue-test --scenario async-burst --count 5
python kkt_client_emulator.py queue-test --scenario sync-chain
python kkt_client_emulator.py queue-test --scenario mixed
```

### Подсценарии `queue-test`

#### `sync-chain` (сценарий 1)

N синхронных `POST /check-marks` **подряд** из одного потока.

- Каждый HTTP-запрос блокируется до полного ответа ККТ.
- Показывает суммарное время цепочки.

#### `async-burst` (сценарий 2)

N async `POST /check-marks` **почти одновременно** (разные потоки).

- HTTP-ответ с `taskId` приходит быстро (миллисекунды).
- Полное завершение на ККТ — последовательно, с большим разбросом по времени.
- В выводе: «Разброс HTTP-ответов» vs «Разброс полного завершения (ККТ)».

#### `mixed` (сценарий 3)

Смешанная нагрузка:

1. `max(2, count // 2)` async `check-marks` (параллельный старт)
2. Сразу sync `check-marks`
3. Сразу sync `print-check`
4. Ожидание завершения всех async-задач

Показывает, как sync-команды ждут освобождения ККТ от async-очереди.

#### `all`

Выполняет подряд: `sync-chain` → `async-burst` → `mixed`.

---

## Тест кэша марок: `mark-cache-test`

Проверка `FMarkCache` в Delphi (этап 1 ТЗ): повторный `check-marks` не ходит на ККТ/РР.

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `--scenario` | `all` | `duplicate-check`, `kkt-rr-cache`, `cancel-reset`, `check-then-print`, `duplicate-items`, `lazy-full-flow`, `all` |
| `--mark` | тестовая КМ | Марка (кодируется в base64) |
| `--check-permission` | off | Во всех сценариях передавать `checkPermission=true` |

```bash
# Главный сценарий этапа 1 (ККТ + РР → повтор из кэша)
python kkt_client_emulator.py mark-cache-test --scenario kkt-rr-cache

# Только дедуп ККТ без РР
python kkt_client_emulator.py mark-cache-test --scenario duplicate-check

# Все сценарии; РР включить везде:
python kkt_client_emulator.py mark-cache-test --check-permission

# Ручная проверка:
python kkt_client_emulator.py check-marks --check-permission
python kkt_client_emulator.py check-marks --check-permission
```

### Подсценарии

| Сценарий | Что проверяет |
|----------|---------------|
| `kkt-rr-cache` | Два `check-marks` с РР: второй `(cached)`, тот же uuid |
| `preflight-print` | `print-check` без check-marks — pre-flight; затем из кэша |
| `preflight-fail` | `print-check` с `FAIL_MARK*` → `result=0` + `marks[]` (этап 4, Emulation) |
| `async-then-print` | async check-marks → status → print из кэша (этап 3) |
| `duplicate-check` | Два `check-marks`: второй из кэша |
| `cancel-reset` | После `cancel-check` кэш сброшен |
| `check-then-print` / `lazy-full-flow` | Печать без `markAccepted` после check |
| `duplicate-items` | Две позиции с одной маркой в одном чеке |

```bash
# Этап 2 — pre-flight
python kkt_client_emulator.py mark-cache-test --scenario preflight-print
python kkt_client_emulator.py print-check --mark-only --check-permission

# Этап 4 — ошибка pre-flight + marks[] (нужен Emulation=true в Delphi)
python kkt_client_emulator.py mark-cache-test --scenario preflight-fail
# через proxy:
python kkt_client_emulator.py mark-cache-test --scenario preflight-fail --port 2579
# (если proxy слушает /kkt — см. base path клиента; обычно порт 2580 напрямую на Delphi)
```

В логе Delphi ожидайте: `полностью из кэша (ККТ+РР) — skip`, `pre-flight begin`, `permission из кэша`.
Для `preflight-fail`: `pre-flight FAIL`, `Отказ ККТ (emulation FAIL_MARK)`.

---

## Формат вывода `queue-test`

Для каждого шага:

```
[11:05:01.234 -> 11:05:01.245] async check-marks #1 (async-mark-0): HTTP 11 мс, taskId=a1b2c3d4..., полное 4.52 с -> OK
```

| Поле | Значение |
|------|----------|
| HTTP … мс | Время до HTTP-ответа сервера |
| полное … с | Время до фактического завершения на ККТ (для async — после poll status) |
| OK / ERR | `result=1` / `result=0` в JSON-ответе |

---

## Endpoints сервера (справочно)

| Метод | Путь |
|-------|------|
| GET | `/health` |
| GET | `/info` |
| POST | `/print-check` |
| POST | `/check-marks` |
| GET | `/check-marks/status?taskId=...` |
| POST | `/close-shift` |
| POST | `/x-report` |
| POST | `/cancel-check` |
| POST | `/disconnect` |

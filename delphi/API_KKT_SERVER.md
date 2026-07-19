# HTTP API сервера ККТ (`kktserverindy`)

Документ описывает контракт **Delphi HTTP-сервера** для интеграции клиента на **любом языке**. Реализация: `uHttpServerFmu.pas`, логика ККТ: `uVariantPrint.pas`.

**Связанные материалы:** схема чека — `ТЗ_print-check_json.md`; примеры вызовов — `kkt_client_emulator.py`, `kkt_client_emulator_scenarios.md`.

---

## 1. Подключение и топология

| Режим | Базовый URL | Пример |
|--------|-------------|--------|
| Напрямую к Delphi | `http://<host>:<port>` | `http://127.0.0.1:2580` |
| Через proxy 1C/FMU | `http://<host>:<proxyPort>/kkt` | `http://127.0.0.1:2579/kkt` |

- Порт Delphi по умолчанию: **2580** (секция `[HttpServer] Port` в INI приложения).
- Proxy снимает префикс `/kkt` и пересылает запрос на Delphi с тем же путём без префикса:  
  `GET http://127.0.0.1:2579/kkt/info` → `GET http://127.0.0.1:2580/info`.

Перед вызовами API нужно запустить `kktserverindy` и нажать **«Старт»** (HTTP-сервер активен).

---

## 2. Транспорт

| Параметр | Значение |
|----------|----------|
| Протокол | HTTP/1.1 |
| Кодировка тела | UTF-8 |
| Запросы с телом | `Content-Type: application/json; charset=utf-8` |
| Ответы | `Content-Type: application/json; charset=utf-8` |
| Рекомендуемый `Accept` | `application/json` |

### 2.1. Успех и ошибки

**Бизнес-успех:** HTTP-код **200–299** и в JSON поле `"result": 1`.

**Бизнес-ошибка:** обычно HTTP **200** с `"result": 0` и `"description": "текст"`.  
Исключения: **404** (`Not found: METHOD path`), **500** (необработанное исключение на сервере) — тело всё равно JSON с `result: 0`.

```json
{"result":1,"description":"OK"}
```

```json
{"result":0,"description":"текст ошибки"}
```

Дополнительные поля зависят от endpoint (см. ниже).

### 2.2. Очередь и таймауты

- Обращения к физической ККТ **сериализуются** (глобальная блокировка): параллельные запросы ждут друг друга.
- Операции с маркировкой и печатью чека могут занимать **десятки секунд** — закладывайте таймаут **120–180 с** на `print-check` и `check-marks` (sync).
- Async-режим `check-marks` быстро возвращает `taskId`; фактическая работа на ККТ идёт в фоне.

### 2.3. Пароль ККТ

Пароль оператора ККТ задаётся **в настройках Delphi** (`FRCash.Password`), не в JSON запросов. Поле `"password"` в теле (как в эмуляторе) **сервером не читается** — можно не передавать.

### 2.4. Опциональное отключение COM

В теле любого POST, который парсится как JSON, можно передать:

```json
{"disconnect": true}
```

После успешного выполнения команды сервер разорвёт соединение с ККТ (вместе с основным телом запроса, например чеком).

---

## 3. Сводная таблица endpoints

| Метод | Путь | Тело | Назначение |
|-------|------|------|------------|
| GET | `/health` | — | Живость HTTP-сервиса (без опроса ККТ) |
| GET | `/info` | — | ИНН, ФН, серийный номер, связь с ККТ |
| GET | `/connection-status` | — | Статус связи + настройки из INI |
| POST | `/connect` | — | Подключение к ККТ (COM) |
| POST | `/disconnect` | — | Отключение от ККТ |
| POST | `/print-check` | JSON чека | Фискальная печать чека |
| POST | `/check-marks` | JSON | Проверка марки(ок) на ККТ |
| GET | `/check-marks/status` | — | Статус async-проверки (`?taskId=`) |
| POST | `/close-shift` | `{}` или JSON | Z-отчёт, закрытие смены |
| POST | `/x-report` | `{}` или JSON | X-отчёт без гашения |
| POST | `/cancel-check` | `{}` или JSON | Отмена открытого чека |
| POST | `/clear-buffer-of-marks` | `{}` или JSON | Очистка буфера маркировки на ФН |

Через proxy: те же пути с префиксом `/kkt`, например `POST /kkt/print-check`.

---

## 4. `GET /health`

Проверка, что HTTP-сервер запущен. **Не** обращается к кассе.

**Ответ при успехе:**

```json
{
  "result": 1,
  "description": "OK",
  "service": "kktserverindy",
  "status": "up",
  "version": "1.0.0.0"
}
```

`version` — версия файла исполняемого модуля.

---

## 5. `GET /info`

Подключение к ККТ (при необходимости) и чтение регистрационных данных.

**Ответ при успехе:**

| Поле | Тип | Описание |
|------|-----|----------|
| `serialNumber` | string | Заводской/серийный номер ККТ |
| `inn` | string | ИНН организации |
| `regNumber` | string | Регистрационный номер ККТ |
| `fnNumber` | string | Номер фискального накопителя |
| `connected` | boolean | Есть активное соединение с ККТ |
| `emulation` | boolean | Режим эмуляции без реального ФР |

Пример:

```json
{
  "result": 1,
  "description": "OK",
  "serialNumber": "1234567890123456",
  "inn": "7700000000",
  "regNumber": "0000000000123456",
  "fnNumber": "9999078901234567",
  "connected": true,
  "emulation": false
}
```

---

## 6. `GET /connection-status`

Статус связи и параметры из конфигурации сервера (без принудительного `Connect`).

**Ответ при успехе (доп. поля):**

| Поле | Описание |
|------|----------|
| `connected` | boolean |
| `comPort` | номер COM-порта |
| `baudRate` | код скорости (как в настройках драйвера) |
| `password` | пароль из настроек (информационно) |
| `cashierName` | имя кассира по умолчанию |
| `httpPort` | порт HTTP |
| `emulation` | boolean |
| `testReceiptMode` | boolean — тестовый режим без отрезки |

---

## 7. `POST /connect` и `POST /disconnect`

**`/connect`** — установить COM-соединение с ККТ.

Успех:

```json
{"result":1,"description":"OK","connected":true}
```

**`/disconnect`** — разорвать соединение.

Успех:

```json
{"result":1,"description":"OK"}
```

---

## 8. `POST /print-check`

Печать фискального чека по JSON. Полная схема — в `ТЗ_print-check_json.md` и `sample-json-check.json`.

### 8.1. Шапка чека

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `type` | string | да | `sell` — приход; `sellReturn` — возврат |
| `taxationType` | string | да | `osn`, `usnIncome`, `usnIncomeOutcome`, `esn`, `patent` |
| `operator` | object | да | `operator.name` — ФИО кассира (открытие смены) |
| `payments` | array | да | Оплаты |
| `total` | number | да | Итог чека |
| `items` | array | да | Позиции и нефискальный текст |

**Оплаты (`payments[]`):**

| `type` | Назначение |
|--------|------------|
| `cash` | Наличные |
| `electronically` | Безнал / электронно |
| `credit` | Кредит |

Несколько элементов с одним `type` суммируются.

### 8.2. Позиция (`items[]`, `type: "position"`)

| Поле | Обяз. | Описание |
|------|-------|----------|
| `name` | да | Наименование |
| `price` | да | Цена за единицу |
| `quantity` | да | Количество |
| `tax` | да | `{ "type": "none" \| "vat20" \| "vat10" \| ... }` |
| `paymentObject` | да | Например `commodity`; при `mark` сервер выставит признак маркированного товара |
| `paymentMethod` | да | Например `fullPayment` |
| `department` | нет | Секция |
| `measurementUnit` | нет | `piece` / `шт` и др. |
| `mark` | нет | Код маркировки, **base64** |
| `markAccepted` | нет | `true` — марка уже принята через `/check-marks` |
| `permission` | нет* | Разрешительный режим для маркированного прихода |

\* Для маркированного **прихода** клиент должен передать `permission` с минимум `uuid` и `time` (см. ТЗ).

### 8.3. Нефискальный текст (`items[]`, `type: "text"`)

```json
{"type": "text", "text": "СКИДКА СУММА 20.00"}
```

Элементы `items` обрабатываются **строго по порядку**.

### 8.4. Ответ при успехе

```json
{
  "result": 1,
  "description": "OK",
  "checkNumber": 42,
  "serialNumber": "1234567890123456"
}
```

После успешной печати сервер **сбрасывает кэш** принятых марок чека.

### 8.5. Маркировка в чеке

- `markAccepted: true` — только отправка марки в чек (без полного онлайн-цикла).
- Поле отсутствует или `false` при наличии `mark` — полный цикл на ККТ при печати (медленнее).

---

## 9. Код маркировки (base64)

В JSON поля `mark` и элементы `marks[]` — **строка base64** от **бинарного** представления кода маркировки (в т.ч. с GS1-разделителем GS, байт `0x1D`).

**Не** передавайте «сырой» КМ с экранированием GS в JSON — сначала соберите байтовую строку, затем base64.

Пример (Python):

```python
import base64

mark_raw = "010460406000301021\u001d91EE10\u001d92..."  # или строка со сканера
mark_b64 = base64.b64encode(mark_raw.encode("latin-1")).decode("ascii")
```

Пример (C#):

```csharp
var bytes = Encoding.Latin1.GetBytes(markRaw);
var markB64 = Convert.ToBase64String(bytes);
```

Декодирование на сервере: стандартный Base64 → посимвольная строка для драйвера ККТ.

---

## 10. `POST /check-marks`

Проверка одной или нескольких марок на ККТ (`FNCheckItemBarcode` + принятие/отклонение). При необходимости автоматически открывается смена (`cashierName` или имя из настроек).

### 10.1. Тело запроса

| Поле | Тип | Обяз. | Описание |
|------|-----|-------|----------|
| `type` | string | нет | `sell` (по умолчанию) или `sellReturn` — тип операции (регистр не важен: `sellreturn`) |
| `mark` | string | * | Одна марка, base64 |
| `marks` | string[] | * | Несколько марок, base64 |
| `cashierName` | string | нет | Кассир при открытии смены |
| `async` | boolean | нет | `true` — немедленный ответ с `taskId` |
| `checkPermission` | boolean | нет | `true` — дополнительно проверка РР через FMU `/document` (только приход) |
| `inn`, `fnNumber` | string | нет | Для РР; если пусто — берутся с ККТ |

\* Обязательно **либо** `mark`, **либо** непустой `marks`.

**Одна марка:**

```json
{
  "type": "sell",
  "mark": "MDEwNDYwNDA2MDAwMzAxMDIxTjRONTdSRENVRFZUTA==",
  "cashierName": "Иванов И.И."
}
```

**Несколько марок:**

```json
{
  "type": "sell",
  "marks": ["...base64...", "...base64..."]
}
```

**Async:**

```json
{
  "type": "sell",
  "mark": "...",
  "async": true
}
```

### 10.2. Ответ (sync, успех)

```json
{
  "result": 1,
  "description": "OK",
  "allAccepted": true,
  "marks": [
    {
      "index": 0,
      "accepted": true,
      "resultCode": 0,
      "checkItemLocalResult": 15,
      "checkItemLocalError": 0,
      "markingType2": 0,
      "kmServerErrorCode": 0,
      "kmServerCheckingStatus": 15,
      "description": "..."
    }
  ]
}
```

При `checkPermission: true` и `type: sell` у элемента `marks[]` может быть вложенный объект `permission` (результат FMU).

Дополнительно на корне: `allPermissionAccepted` (boolean).

**Решение клиента:** для допуска к продаже обычно достаточно `allAccepted === true` и у каждой нужной марки `accepted === true`.

### 10.3. Ответ (async, принятие задачи)

```json
{
  "result": 1,
  "description": "OK",
  "async": true,
  "taskId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "status": "pending"
}
```

Далее опрос **§11**.

---

## 11. `GET /check-marks/status`

**Query:** `taskId` — обязателен (как в async-ответе).

**Пока задача выполняется:**

```json
{
  "result": 1,
  "description": "OK",
  "taskId": "...",
  "status": "pending"
}
```

**Завершено (`status`: `completed` или `error`):** в ответе те же поля, что у sync `/check-marks`, плюс `taskId` и `status`. Тело результата — из фоновой задачи (включая `result`, `marks`, `allAccepted`, `permission`).

Ошибки: `taskId is required`, `task not found`.

Рекомендуемый интервал опроса: 0.5–2 с, таймаут ожидания: до 180 с.

**Ленивый клиент 1С:** poll status **не обязателен**. Async `check-marks` по завершении пишет результат в серверный `FMarkCache`; при `print-check` Delphi сам возьмёт марки из кэша (или допроверит в pre-flight). Poll нужен только для UI «проверяется / OK / ошибка» на форме.

---

## 12. Служебные команды ККТ

Тело может быть пустым, `{}` или произвольный JSON (парсится, на логику не влияет).

### 12.1. `POST /close-shift`

Z-отчёт с гашением.

**Успех:**

```json
{
  "result": 1,
  "description": "OK",
  "documentNumber": 15
}
```

`documentNumber` — номер документа/смены после закрытия (как читает сервер с ККТ).

### 12.2. `POST /x-report`

X-отчёт без гашения.

**Успех:** `{"result":1,"description":"OK"}`

### 12.3. `POST /cancel-check`

Отмена открытого чека на ККТ; сбрасывается кэш принятых марок.

**Успех:** `{"result":1,"description":"OK"}`

### 12.4. `POST /clear-buffer-of-marks`

`FNMarkingClearBuffer` + сброс кэша марок на сервере.

**Успех:** `{"result":1,"description":"OK"}`

---

## 13. Типичные сценарии клиента

### 13.1. Старт смены / диагностика

1. `GET /health` — сервис жив.
2. `GET /info` — `connected`, `inn`, `fnNumber` для внешних систем.

### 13.2. Продажа с маркой (рекомендуемый поток)

1. `POST /check-marks` с `mark` (sync) → `allAccepted` и `accepted`.
2. `POST /print-check` с позицией: `mark`, `markAccepted: true`, `permission` (uuid/time для РР).
3. Сохранить `checkNumber`, `serialNumber` из ответа.

### 13.3. «Ленивый» клиент

Один вызов `POST /print-check` с `mark` без `markAccepted` — сервер выполнит полный маркировочный цикл при печати (дольше по времени).

### 13.4. Конец смены

1. При необходимости `POST /cancel-check`.
2. `POST /close-shift` → `documentNumber`.

---

## 14. Минимальный клиент (псевдокод)

```
function api(method, path, body=None):
    req = HTTP(method, baseUrl + path)
    req.header("Content-Type", "application/json; charset=utf-8")
    req.header("Accept", "application/json")
    req.timeout = 180
    if body != None:
        req.body = JSON.stringify(body)  // UTF-8
    resp = req.send()
    data = JSON.parse(resp.body)
    if resp.status not in 200..299 or data.result != 1:
        raise Error(data.description or resp.body)
    return data

// Печать
api("POST", "/print-check", receiptObject)

// Проверка марки
r = api("POST", "/check-marks", {"type":"sell", "mark": markB64})
assert r.allAccepted and r.marks[0].accepted
```

Через proxy замените пути: `/kkt/print-check`, `/kkt/check-marks`, и т.д.

---

## 15. Ограничения

- Один логический поток операций на одну ККТ, настроенную в Delphi; мульти-касса — отдельные инстансы/настройки COM.
- Не полагайтесь на параллельную печать нескольких чеков с одного сервера — запросы выстраиваются в очередь.
- Старые задачи async (`taskId`) могут удаляться с сервера (хранится ограниченное число записей).
- В режиме `emulation` ответы могут быть успешными без реального ФР (для разработки).

---

## 16. Проверка интеграции

- Прямой сервер: `python kkt_client_emulator.py smoke`
- Через proxy: `python proxy_1c_client_emulator.py smoke`
- Чек из файла: `python kkt_client_emulator.py print-check --json sample-json-check.json`

Успешный smoke подтверждает совместимость клиента с контрактом API.

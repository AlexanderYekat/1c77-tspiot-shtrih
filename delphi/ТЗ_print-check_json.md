# ТЗ: `POST /print-check` — JSON чека и доработка Delphi

**Статус:** реализовано (Delphi + эмулятор).  
**Дата:** 2026-07-05

---

## 1. Идея

JSON делится на две части:

1. **Фискальные данные** — сервер передаёт в ККТ (драйвер Штрих).
2. **Нефискальные данные** — клиент передаёт элементами `"type": "text"` в `items[]`, сервер печатает через `PrintString`.

Сервер **не** генерирует скидочные строки, код продавца и прочее — это ответственность клиента (1С).

---

## 2. Структура JSON

### 2.1. Шапка чека (фискальное)

| Поле | Тип | Обяз. | Описание | ККТ |
|------|-----|-------|----------|-----|
| `type` | string | да | `sell` — приход, `sellReturn` — возврат/расход | `CheckType` 0 / 2 |
| `taxationType` | string | да | СНО: `osn`, `usnIncome`, `usnIncomeOutcome`, `esn`, `patent` | тег 1055 |
| `operator.name` | string | да | ФИО кассира | открытие смены, тег 1021 |
| `payments` | array | да | Оплаты (см. ниже) | `Summ1`, `Summ2`, … |
| `total` | number | да | Итог чека | контроль при закрытии |
| `items` | array | да | Позиции и текст (см. ниже) | — |

Оплаты:

```json
"payments": [
  { "type": "cash", "sum": 100.00 },
  { "type": "electronically", "sum": 50.00 }
]
```

| `payments[].type` | ККТ |
|-------------------|-----|
| `cash` | `Summ1` |
| `electronically` | `Summ2` |
| `credit` | `Summ15` |

Смешанная оплата: несколько элементов в `payments[]`, суммы складываются по типам.

---

### 2.2. Позиция (`type: "position"`)

| Поле | Тип | Обяз. | Описание | ККТ |
|------|-----|-------|----------|-----|
| `type` | `"position"` | да | — | — |
| `name` | string | да | Наименование | `StringForPrinting` |
| `price` | number | да | Цена за ед. с учётом скидок | `Price` |
| `quantity` | number | да | Количество | `Quantity` |
| `tax.type` | string | да | Ставка НДС (см. таблицу) | `Tax1` |
| `paymentObject` | string | да | Предмет расчёта | `PaymentItemSign` |
| `paymentMethod` | string | да | Способ расчёта | `PaymentTypeSign` |
| `department` | number | нет | Секция (default из настроек) | `Department` |
| `measurementUnit` | string | нет | `piece` / `шт` → шт., иначе ед. | `MeasureUnit` |
| `mark` | string | нет | КМ для ККТ (base64) | маркировочный цикл |
| `markAccepted` | bool | нет* | Марка уже принята ККТ | см. §3 |
| `permission` | object | нет** | Данные разрешительного режима | теги 1262–1265 |

\* Обязателен, если передан `mark`.  
\*\* Обязателен для маркированной позиции прихода — 1С всегда присылает готовый объект.

**`tax.type` → `Tax1` (Штрих):**

| tax.type | Tax1 |
|----------|------|
| `none` | 0 |
| `vat20` | 1 |
| `vat10` | 2 |
| `vat0` | 3 |
| `vat120` | 5 |
| `vat110` | 6 |
| `vat5` | 7 |
| `vat7` | 8 |
| `vat105` | 9 |
| `vat107` | 10 |

**`paymentObject` → `PaymentItemSign`:**

| paymentObject | Значение |
|---------------|----------|
| `commodity` | 1 (товар) |
| с полем `mark` | 33 |
| `excise`, `service`, … | по справочнику ФФД при необходимости |

**`paymentMethod` → `PaymentTypeSign`:**

| paymentMethod | Значение |
|---------------|----------|
| `fullPayment` | 4 (полный расчёт) |
| `advance`, `fullPrepayment`, `credit`, … | по справочнику ФФД |

**Разрешительный режим (`permission`):**

```json
"permission": {
  "uuid": "00000000-0000-0000-0000-000000000001",
  "time": "2026-07-05T10:00:00",
  "tag1262": "030",
  "tag1263": "21.11.2023",
  "tag1264": "1944"
}
```

| Поле | Тег | Обяз. | По умолчанию |
|------|-----|-------|--------------|
| `uuid` | 1265 (часть значения) | да* | — |
| `time` | 1265 (часть значения) | да* | — |
| `tag1262` | 1262 (идентификатор ФОИВ) | нет | `030` |
| `tag1263` | 1263 (дата основания) | нет | `21.11.2023` |
| `tag1264` | 1264 (номер основания) | нет | `1944` |

\* Обязательны для отправки тегов РР. Если `uuid`+`time` переданы, а `tag1262`–`tag1264` нет — сервер подставляет значения по умолчанию.

1С **всегда** присылает `permission` для маркированных позиций прихода (минимум `uuid`+`time`).  
После `FNOperation` сервер отправляет теги 1262, 1263, 1264, 1265.

Если `permission` не передан (нештатно) — **заглушка:** теги РР не отправляются, в лог пишется предупреждение. В будущем можно добавить самостоятельное получение uuid/time.

---

### 2.3. Нефискальный текст (`type: "text"`)

Всё нефискальное: скидки, код продавца, «Оплата по терминалу», накопление, акции, разделители.

```json
{
  "type": "text",
  "text": "СКИДКА СУММА 20.00"
}
```

**ККТ:** `UseReceiptRibbon = 1`, `StringForPrinting = text`, `PrintString`.

---

## 3. Логика маркировки в чеке

Для позиции с `mark`:

```
FNOperation (фискальная позиция)
  ↓
если есть permission → теги 1262–1265
  ↓
если markAccepted = true
  → FNSendItemBarcode (марка уже проверена ранее)
иначе
  → полный цикл проверки и привязки марки:
     FNCheckItemBarcode → FNSendItemBarcode → FNAcceptMarkingCode → FNSendItemBarcode
```

`markAccepted: false` или поле отсутствует при наличии `mark` — **всегда** полный цикл.

Endpoint `/check-marks` — для предварительной проверки; при печати чека клиент ставит `markAccepted: true`, если марка уже принята.

---

## 4. Порядок обработки `items[]`

Элементы обрабатываются **по порядку**:

| type | Действие |
|------|----------|
| `position` | `FNOperation` + РР + маркировка |
| `text` | `PrintString` |

После всех `items` — `FNCloseCheckEx` по `payments` и `total`, затем отрез.

---

## 5. Пример полного чека

```json
{
  "type": "sell",
  "taxationType": "usnIncome",
  "operator": {
    "name": "Емельянов Алексей Андреевич"
  },
  "items": [
    {
      "type": "position",
      "name": "Шлем неопреновый",
      "price": 200.00,
      "quantity": 1,
      "department": 1,
      "tax": { "type": "none" },
      "paymentObject": "commodity",
      "paymentMethod": "fullPayment",
      "mark": "MDEwNDYwNDA2MDAwMzAxMDIxTjRONTdSRENVRFZUTA==",
      "markAccepted": false,
      "permission": {
        "uuid": "00000000-0000-0000-0000-000000000001",
        "time": "2026-07-05T10:00:00"
      }
    },
    { "type": "text", "text": " " },
    { "type": "text", "text": "Код продавца 42" }
  ],
  "payments": [
    { "type": "electronically", "sum": 200.00 }
  ],
  "total": 200.00
}
```

---

## 6. Что было / что сделано

| Что | Было | Стало |
|-----|------|-------|
| `type`, `taxationType`, `operator.name` | не читались | парсятся, `EnsureSessionOpen` по оператору |
| `tax`, `paymentObject`, `paymentMethod` | захардкожены | маппинг из JSON |
| `type: "text"` → `PrintString` | нет | `PrintReceiptText` |
| `payments[]` (нал + безнал) | только один вид оплаты | суммирование по типам |
| Полный цикл маркировки | только `FNSendItemBarcode` | `ProcessMarkingAfterFNOperation` |
| `markAccepted` | нет | ветка «только FNSendItemBarcode» |
| `permission` | uuid+time на позиции | объект `permission`, заглушка + лог |
| `EnsureSessionOpen` при печати чека | нет | вызывается в `PrintCheckJson` |

---

## 7. План работ — выполнено

1. ~~Парсинг JSON по этой схеме.~~
2. ~~Шапка: `type`, `taxationType`, `operator`, `payments`, открытие смены.~~
3. ~~Позиция: все фискальные поля.~~
4. ~~Маркировка: ветка `markAccepted` / полный цикл.~~
5. ~~РР: `permission` (без `permission` — заглушка, только лог).~~
6. ~~`type: "text"` → `PrintString`.~~
7. ~~Обновить эмулятор и `sample-json-check.json`.~~

---

*После ревью — реализация по §7.*

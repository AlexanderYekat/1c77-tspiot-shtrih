# План: ленивый клиент 1С + Delphi как хранилище и оркестратор проверки марок

**Дата:** 2026-07-12  
**Статус:** этапы 1–4 done, 5.1+5.3 done; далее этап 8 (маппинг) / 7 / 5.2  
**Связанные документы:** `ПЛАН_доработка_1с_ккт.md`, `delphi/ТЗ_клиент_1cv77.md`, `delphi/ТЗ_print-check_json.md`

---

## Суть подхода

1С **не хранит** состояние проверки марок как источник правды.  
Delphi (`kktserverindy`, `uVariantPrint.pas`) — **единый кэш и исполнитель**:

- async/sync `POST /check-marks`
- `GET /check-marks/status`
- in-memory кэш результатов **ККТ + РР**
- при `print-check` — сам решает, что уже проверено, что нет

1С делает минимум:

| Когда | Что делает 1С |
|-------|---------------|
| Скан марки | запускает async `check-marks` (опционально poll status) |
| Печать чека | шлёт JSON с марками **без** `markAccepted` и **без** `permission` |
| Ошибка | сопоставляет `marks[]` из ответа ↔ строки чека → `razresh_regim_dialog_error` |

```text
Форма чека 1С
    ↓ async check-marks (при скане)
fr_elves-12
    ↓
razresh_regim_check  →  permissive_regime_2024  →  proxy :2579/kkt/...
    ↓
Delphi kktserverindy (кэш + проверка + печать)
```

---

## Текущее состояние (baseline)

| Компонент | Есть | Не хватает |
|-----------|------|------------|
| Delphi `POST /check-marks` sync/async | ✅ | — |
| Delphi `GET /check-marks/status` | ✅ | — |
| Delphi `FMarkCache` (ККТ + РР, uuid/time) | ✅ (этап 1) | — |
| Delphi `print-check` pre-flight по маркам | ✅ (этап 2) | — |
| Delphi permission из кэша при печати | ✅ (этап 2) | — |
| 1С async при скане (`module-form-of-check`) | ✅ частично | poll + UI не доведены |
| 1С блок РР перед печатью (723–759) | ✅ старый путь | убрать/заменить для внешней программы |
| `razresh_regim_dialog_error` | ✅ | колонка ошибки ККТ |
| `ОбновитьСписокМарокПоТаблицеРезультатов` | ✅ | использовать при ошибках печати |

---

## Целевой поток

### A. Сканирование марки (форма документа)

```text
1. Кассир сканирует КМ
2. 1С → async POST /check-marks (checkPermission=true, одна марка)
3. Delphi: проверяет ККТ + РР, кладёт результат в кэш, taskId → pending → completed
4. (Опционально) 1С poll GET /check-marks/status — для индикатора «проверяется / OK / ошибка»
5. 1С НЕ обязана сохранять UUID/флаги в таблице — достаточно Delphi-кэша
```

### B. Печать чека

```text
1. 1С → POST /print-check (items с mark, без markAccepted, без permission)
2. Delphi pre-flight:
   a. Собрать все mark из items[]
   b. Для каждой: если в кэше OK (ККТ + РР при необходимости) → skip
   c. Иначе → проверить (как check-marks)
   d. Если есть ошибки → result=0, marks[] с per-mark ошибками, чек НЕ печатать
   e. Если всё OK → печать с markAccepted=true, permission из кэша
3. 1С: при result=0 → маппинг marks[] → строки → razresh_regim_dialog_error
4. Диалог: «Пробить всё равно» / «Отмена»
```

### C. Сопоставление марок (1С)

Ключ сопоставления: **base64 марки** (`МаркаВBase64`), как в `fr_elves_test.txt`.  
Не по сырой строке с GS — возможны расхождения формата.

---

## Этап 1. Delphi — расширенный кэш марок

**Файл:** `delphi/uVariantPrint.pas`

### 1.1. Структура записи кэша

- [x] Заменить `FAcceptedMarks: TDictionary<string, Byte>` на `FMarkCache: TDictionary<string, TMarkCacheEntry>`
- [x] Ключ: `MarkCacheKey(MarkDecoded, ReturnCheck)` → `"S|..."` / `"R|..."` (как сейчас)
- [x] Поля `TMarkCacheEntry`:
  - `KktAccepted: Boolean`
  - `KktResultCode: Integer`
  - `KktDescription: string`
  - `RrAccepted: Boolean` (если РР не проверялся — `True` или отдельный флаг `RrChecked`)
  - `RrCode: Integer`
  - `RrDescription: string`
  - `Uuid, TimeStr, Inst, Version: string`
  - `CheckedAt: TDateTime`

### 1.2. Обновление кэша

- [x] После успешной проверки в `CheckSingleMark` — записать KKT-поля
- [x] После `CheckSingleMarkPermission` — записать RR-поля (uuid, time, inst, version, ошибки)
- [x] В `CheckMarkInternal` после цикла по маркам — обновить кэш для каждой марки из `marks[]`
- [x] При cache hit в `CheckSingleMark` — возвращать результат **из записи кэша** (не только `accepted=true`)

### 1.3. API чтения кэша (внутреннее)

- [x] `function TryGetMarkFromCache(MarkDecoded, ReturnCheck): TMarkCacheEntry`
- [x] `function IsMarkFullyOk(MarkDecoded, ReturnCheck, CheckPermission): Boolean`
  - ККТ accepted = true
  - если `CheckPermission` и не возврат → RR accepted = true и uuid/time заполнены

### 1.4. Сброс кэша

- [x] Сохранить текущее поведение: `ClearAcceptedMarksCache` после успешной печати, close-shift, cancel-check
- [x] Переименовать в `ClearMarkCache` (или аналог)
- [x] **Не** сбрасывать кэш при ошибке pre-flight print-check (марки уже проверены, результат известен)

**Критерий завершения этапа 1:** ✅  
После sync `check-marks` повторный вызов для той же марки не ходит на ККТ/РР, а отдаёт данные из кэша с полями KKT + RR.  
Проверено: `mark-cache-test --scenario kkt-rr-cache` / `duplicate-check` (2026-07-19).

---

## Этап 2. Delphi — pre-flight в `print-check`

**Файл:** `delphi/uVariantPrint.pas`, функция `PrintCheckJson`

### 2.1. Pre-flight перед печатью

- [x] Новая процедура `EnsureMarksReadyForPrint(Req: TJSONObject): string` (JSON ошибки или пусто = OK)
- [x] Собрать все `mark` (base64) из `items[]` где `type=position`
- [x] Определить `ReturnCheck`, `CheckPermission` (из JSON или настройки: РР только для `sell`, не для `sellReturn`)
- [x] Для каждой марки:
  - [x] cache hit + fully ok → skip
  - [x] иначе → `CheckSingleMark` + при необходимости `CheckSingleMarkPermission`
- [x] Сформировать ответ при ошибках:

```json
{
  "result": 0,
  "description": "Не все марки прошли проверку",
  "allAccepted": false,
  "allPermissionAccepted": false,
  "marks": [
    {
      "index": 0,
      "mark": "<base64>",
      "accepted": false,
      "description": "ошибка ККТ ...",
      "permission": {
        "accepted": false,
        "code": 100,
        "error": "ошибка РР ..."
      }
    }
  ]
}
```

- [x] При `result=0` — **не** вызывать `FNOperation` / не открывать чек на ККТ

### 2.2. Печать с данными из кэша

- [x] В `RegisterReceiptItem`: если `permission` в JSON пуст — **подставить из кэша** по `MarkDecoded`
- [x] В `ProcessMarkingAfterFNOperation`: всегда `markAccepted=true` для марок, прошедших pre-flight
- [x] Логировать: «permission из кэша», «markAccepted из pre-flight»

### 2.3. Флаг отключения pre-flight (опционально)

- [x] JSON `"skipMarkPreflight": true` — для отладки / «пробить всё равно» с стороны 1С (если понадобится)

**Критерий завершения этапа 2:** ✅  
`python kkt_client_emulator.py mark-cache-test --scenario preflight-print` (2026-07-19, v2026.7.19.2):
- первая попытка → pre-flight проверяет и печатает
- вторая (после check-marks) → `pre-flight [1]: из кэша — skip`, `permission из кэша`

---

## Этап 3. Delphi — async и status (доработки)

**Файл:** `delphi/uVariantPrint.pas`

### 3.1. Async check-marks

- [x] Убедиться, что после `StartAsyncCheckMark` результат в `FMarkTasks` содержит полный `marks[]` с permission
- [x] По завершении async — обновить `FMarkCache` (через `CheckMarkInternal` в фоновом потоке под `FLock`)

### 3.2. Status endpoint

- [x] `GET /check-marks/status?taskId=...` — без изменений контракта
- [x] Документировать: 1С может не poll'ить — достаточно кэша при печати (`API_KKT_SERVER.md` §11)

### 3.3. (Опционально) GET /kkt/marks-cache-status

- [ ] Endpoint: передать `marks[]` base64 → ответ статуса из кэша без проверки
- [ ] Нужен только если захотим UI «зелёная галочка» на форме без poll taskId
- [x] **Не в MVP** — отложить

**Критерий завершения этапа 3:** ✅  
Async check-marks → poll status → кэш заполнен → print-check без повторной проверки.  
Проверено: `mark-cache-test --scenario async-then-print` (2026-07-19).

---

## Этап 4. Proxy / permissive_regime_2024 — без изменений контракта

**Файлы:** `csharp/.../proxy`, `1cv77/permissive_regime_2024.txt`

- [x] Убедиться, что proxy пробрасывает новые поля `marks[]` при `result=0` от print-check  
  (`ProxyForwarder` — прозрачный byte-copy тела ответа, без фильтрации JSON)
- [x] `permissive_regime_2024`: разбор `marks[]` при ошибке print-check  
  (`РазборККТПриОшибке` → `РазобратьОтветККТ`; колонка `mark` base64 в `таблМарки`)
- [x] `СформироватьСтруктурированныйРезультатККТ` / аналог — поля `таблМарки` при ошибке печати  
  (уже пробрасывал; теперь upstream заполняет `таблМарки` и при `кодОшибки=30`)

**Критерий завершения этапа 4:** ✅  
Ошибка print-check с `marks[]` доходит до 1С в `таблМарки` (через `ПечатьЧекаККТ` → `ЗаполнитьПараметрыРезультатаККТ` → `razresh_regim_check`).  
Проверка: `python kkt_client_emulator.py mark-cache-test --scenario preflight-fail` + кнопка `КнопкаПечатьЧекаПлохаяМарка` в `fr_elves_test` (Emulation=true).

---

## Этап 5. 1С — `fr_elves-12`: упрощение перед печатью

**Файл:** `1cv77/fr_elves-12.ert.txt`, процесс `печатать_чек` (~707+)

### 5.1. Убрать дублирующую логику РР для внешней программы

- [x] При `глИспользоватьВнешнуюПрограмму… = 1` **убрать** блок `ЗапусититьПроверкуРазрешительныйРежим` перед печатью  
  (РР остаётся только для старого пути DrvFR, флаг = 0)
- [x] **Убрать** условие «если все UUID есть — пропустить РР» (больше не нужно для внешней программы)
- [x] Не передавать `markAccepted` и `permission` в JSON чека (Delphi возьмёт из кэша)

**Проверка 5.1:** кнопка `КнопкаПечатьЧекаПлохаяМарка` → в логе Delphi `POST /print-check` + `pre-flight FAIL`; в 1С `таблМарки` без диалога РР `/document`.

### 5.2. Обработка ошибки print-check

- [ ] Если `ПечатьЧекаЧерезВнешнююПрограмму` вернула ошибку и есть `таблМарки`:
  - [ ] Сопоставить марки с `СписокТоваров` (по base64)
  - [ ] Заполнить в строках: `ККТОписаниеОшибки`, `РРОписаниеОшибки` (новые колонки при необходимости)
  - [ ] Вызвать `razresh_regim_dialog_error` модально
  - [ ] Если «Пробить чек» = 0 → `Результат=0`, возврат
  - [ ] Если «Пробить чек» = 1 → повтор print-check с `skipMarkPreflight=true` (если реализован) **или** явное решение: не пробивать при ошибках марок (рекомендуется)

### 5.3. Сборка JSON чека

- [x] `СобратьJSONЧекаДляВнешнейПечати`: для маркированных позиций — только `mark` (base64)  
  (сделано вместе с 5.1 в `СформироватьJSONПозицииЧека`)
- [x] Не добавлять `markAccepted`, `permission` (Delphi pre-flight)

**Критерий завершения этапа 5:**  
Печать через внешнюю программу не вызывает `ЗапусититьПроверкуРазрешительныйРежим`; при ошибке марок показывается диалог.  
(5.1+5.3 done; диалог — 5.2 после этапов 8/7)

---

## Этап 6. 1С — форма сканирования (ленивый async)

**Файл:** `1cv77/module-form-of-check.txt`

### 6.1. Async при скане

- [ ] После `ВыполнитьПроверкуМарокАсинхронно` — сохранять `taskId` (локальная переменная формы или скрытое поле)
- [ ] **Не обязательно** poll — достаточно fire-and-forget

### 6.2. (Опционально) Poll для UI

- [ ] Таймер / повторный вызов `получить_статус_задания` каждые 300–500 мс
- [ ] Индикатор в строке: «проверяется» / «OK» / «ошибка»
- [ ] **Не в MVP** — можно отложить

### 6.3. Параметры check-marks при скане

- [ ] `ПроверятьРР = 1` если `вклРазрешительныйРежим = 1` и не возврат
- [ ] Передавать `ИНН`, `ФН` (из подключения к ККТ или константы)

**Критерий завершения этапа 6:**  
Скан марки запускает async check-marks с РР; без блокировки формы.

---

## Этап 7. 1С — `razresh_regim_dialog_error`

**Файл:** `1cv77/razresh_regim_dialog_error.txt`

### 7.1. Расширить таблицу ошибок

- [ ] Колонка `ККТОписаниеОшибки` (строка)
- [ ] Колонка `РРОписаниеОшибки` (уже есть)
- [ ] Колонка `Маркировка` — укороченное представление (последние N символов)
- [ ] Выгрузка: `ТовНаим, Количество, Цена, Сумма, ККТОписаниеОшибки, РРОписаниеОшибки, Маркировка`

### 7.2. Кнопки

- [ ] «Отмена» — `Пробить чек = 0` (как сейчас при закрытии без кнопки)
- [ ] «Пробить всё равно» — `Пробить чек = 1` (если бизнес-правило разрешает; иначе убрать кнопку)

**Критерий завершения этапа 7:**  
При ошибках печати кассир видит строку чека + ошибку ККТ + ошибку РР.

---

## Этап 8. 1С — вспомогательные функции

**Файлы:** `fr_elves-12.ert.txt`, `razresh_regim_check.txt`

### 8.1. Сопоставление марок

- [ ] `СопоставитьОшибкиМарокСТаблицейЧека(СписокТоваров, таблМарки)`
  - для каждой строки `таблМарки` найти позицию в `СписокТоваров` по `МаркаВBase64`
  - записать ошибки в колонки строки

### 8.2. Показ диалога ошибок

- [ ] `ПоказатьДиалогОшибокМарок(СписокТоваров) → ПробитьЧек (0/1)`
  - обёртка над `razresh_regim_dialog_error.ert`

### 8.3. `razresh_regim_check`

- [ ] Без новой команды «ensure-marks» — **не нужна** в этом подходе
- [ ] Существующие `check-mark`, `check-mark-status`, `print-check` — без изменений логики

**Критерий завершения этапа 8:**  
Единая функция маппинга ошибок, вызываемая из `печатать_чек`.

---

## Этап 9. Тестирование

### 9.1. Delphi (emulator / smoke)

- [x] `check-marks` sync — одна марка, `allAccepted=true`, кэш заполнен
- [x] `check-marks` async — taskId, poll до completed, кэш заполнен
- [x] `print-check` без предварительного check-marks — pre-flight проверяет и печатает
- [x] `print-check` после check-marks — из кэша, без повторного FNCheckItemBarcode (по логу)
- [ ] `print-check` с заведомо bad маркой — `result=0`, `marks[]` с ошибками, чек не пробит  
  (smoke: `mark-cache-test --scenario preflight-fail`, Emulation + `FAIL_MARK*`)
- [x] РР: `checkPermission=true`, uuid/time в кэше, теги 126x уходят при печати
- [ ] Возврат `sellReturn` — РР не проверяется
- [ ] Рестарт Delphi — кэш пуст, pre-flight проверяет заново

### 9.2. 1С (fr_elves_test / ручные сценарии)

- [ ] Скан → async (fire-and-forget)
- [ ] Печать чека с марками — успех без блока РР в fr_elves
- [ ] Печать с bad маркой — диалог ошибок, строки сопоставлены
- [ ] «Отмена» в диалоге — чек не пробит
- [ ] Чек без марок — без изменений
- [ ] `глИспользоватьВнешнуюПрограмму = 0` — старый путь DrvFR без регрессии

### 9.3. Регрессия

- [ ] Nefiskальnye stroki cheka — порядок и содержание как раньше
- [ ] `close-shift`, `x-report`, `cancel-check` — работают
- [x] Очистка кэша после успешной печати

**Критерий завершения этапа 9:**  
Все сценарии из §9.1–9.2 пройдены, задокументированы в `fr_elves_test.txt` или отдельном чек-листе.

---

## Порядок работ (рекомендуемый)

```text
Этап 1 (Delphi: кэш)           ✅
    ↓
Этап 2 (Delphi: pre-flight)    ✅
    ↓
Этап 3 (Delphi: async → кэш)   ✅
    ↓
Этап 4 (proxy/1С транспорт)    ✅
    ↓
Этап 5.1+5.3 (убрать РР / JSON) ✅  ← только что
    ↓
Этап 8 (1С: маппинг ошибок)    ← сейчас
    ↓
Этап 7 (dialog_error UI)
    ↓
Этап 5.2 (диалог при ошибке печати)
    ↓
Этап 6 (форма сканирования)
    ↓
Этап 9 (тестирование)
```

---

## Итоговые критерии приёмки

- [ ] 1С при печати шлёт только марки; Delphi сам проверяет и использует кэш
- [x] Повторная проверка уже OK марки не дублирует запросы к ККТ/РР (видно в логе Delphi)
- [ ] При ошибке print-check 1С показывает `razresh_regim_dialog_error` с ошибками ККТ и РР по строкам
- [x] РР-теги (uuid/time) уходят в ФН при печати из кэша Delphi, без `permission` в JSON от 1С
- [ ] Async при скане не блокирует форму
- [ ] Старый режим DrvFR (`флаг = 0`) не сломан

---

## Ограничения и допущения

| Тема | Решение |
|------|---------|
| Жизнь кэша | In-memory, только пока работает процесс Delphi |
| Одна касса | Один инстанс kktserverindy на кассу |
| «Пробить всё равно» | Бизнес-решение: по умолчанию **не** пробивать при ошибках марок |
| Poll при скане | Опционально, не блокер MVP |
| GET marks-cache-status | Опционально, не в MVP |

---

## Вне scope

- Персистентный кэш на диске
- UI настроек proxy / РР
- Полноценный JSON-парсер в 1С (достаточно текущего)
- Новая команда `ensure-marks` в razresh_regim_check (Delphi всё решает сам)

---

## Чек-лист «готово к prod»

- [x] Этапы 1–2 (Delphi) — done
- [ ] Этапы 5, 7, 8 (1С) — done
- [ ] Этап 9 — все сценарии green
- [ ] Обновлён `fr_elves_test.txt` под новый поток
- [ ] Краткая инструкция кассиру: «сканируй марку → жди / не жди → пробивай чек»

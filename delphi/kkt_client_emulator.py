#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Эмулятор HTTP-клиента для Delphi KKT-сервера (kktserverindy).

Сервер по умолчанию слушает порт 2580 и предоставляет endpoints:
  GET  /health
  GET  /info
  POST /print-check
  POST /close-shift
  POST /x-report
  POST /cancel-check
  POST /disconnect
  POST /check-marks
  GET  /check-marks/status?taskId=...

Примеры:
  python kkt_client_emulator.py health
  python kkt_client_emulator.py info
  python kkt_client_emulator.py smoke
  python kkt_client_emulator.py print-check --json receipt.json
  python kkt_client_emulator.py close-shift --password 30
  python kkt_client_emulator.py queue-test
  python kkt_client_emulator.py queue-test --scenario async-burst --count 5
  python kkt_client_emulator.py mark-cache-test
  python kkt_client_emulator.py mark-cache-test --scenario check-then-print
  python kkt_client_emulator.py mark-cache-test --scenario cancel-reset
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
import threading
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Any


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 2580
DEFAULT_TIMEOUT = 180
DEFAULT_MARK_RAW = "010460406000301021N4N57RDCUDVTL"


@dataclass
class HttpResponse:
    status: int
    body: str
    json: dict[str, Any] | None

    @property
    def ok(self) -> bool:
        if self.json is None:
            return False
        return self.json.get("result") == 1


class KktServerClient:
    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        timeout: int = DEFAULT_TIMEOUT,
    ) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.base_url = f"http://{host}:{port}"

    def clone(self) -> KktServerClient:
        return KktServerClient(host=self.host, port=self.port, timeout=self.timeout)

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> HttpResponse:
        url = f"{self.base_url}{path}"
        data = None
        headers: dict[str, str] = {}

        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            status = exc.code
        except urllib.error.URLError as exc:
            raise ConnectionError(
                f"Не удалось подключиться к {url}: {exc.reason}. "
                "Запустите kktserverindy и нажмите «Старт»."
            ) from exc

        parsed: dict[str, Any] | None
        try:
            parsed = json.loads(raw) if raw.strip() else None
        except json.JSONDecodeError:
            parsed = None

        return HttpResponse(status=status, body=raw, json=parsed)

    def health(self) -> HttpResponse:
        return self.request("GET", "/health")

    def info(self) -> HttpResponse:
        return self.request("GET", "/info")

    def print_check(self, payload: dict[str, Any]) -> HttpResponse:
        return self.request("POST", "/print-check", payload)

    def close_shift(self, password: int = 30) -> HttpResponse:
        return self.request("POST", "/close-shift", {"password": password})

    def x_report(self, password: int = 30) -> HttpResponse:
        return self.request("POST", "/x-report", {"password": password})

    def cancel_check(self, password: int = 30) -> HttpResponse:
        return self.request("POST", "/cancel-check", {"password": password})

    def disconnect(self) -> HttpResponse:
        return self.request("POST", "/disconnect")

    def check_marks(self, payload: dict[str, Any]) -> HttpResponse:
        return self.request("POST", "/check-marks", payload)

    def check_marks_status(self, task_id: str) -> HttpResponse:
        query = urllib.parse.urlencode({"taskId": task_id})
        return self.request("GET", f"/check-marks/status?{query}")


def sample_receipt(
    *,
    password: int = 30,
    payment: int = 0,
    with_marking: bool = False,
    mark_accepted: bool = False,
    sell_return: bool = False,
    mark_raw: str = DEFAULT_MARK_RAW,
) -> dict[str, Any]:
    """Тестовый чек в формате POST /print-check (ТЗ print-check_json)."""
    items: list[dict[str, Any]] = [
        {
            "type": "position",
            "name": "Товар без марки",
            "quantity": 1,
            "price": 100.0,
            "department": 1,
            "tax": {"type": "none"},
            "paymentObject": "commodity",
            "paymentMethod": "fullPayment",
        },
        {
            "type": "position",
            "name": "Второй товар",
            "quantity": 2,
            "price": 25.0,
            "department": 1,
            "tax": {"type": "vat20"},
            "paymentObject": "commodity",
            "paymentMethod": "fullPayment",
        },
        {"type": "text", "text": " "},
        {"type": "text", "text": "Код продавца 42"},
    ]

    if with_marking:
        items.insert(
            2,
            mark_position_item(
                name="Маркированный товар",
                mark_raw=mark_raw,
                mark_accepted=mark_accepted,
            ),
        )

    total = sum(
        item["price"] * item["quantity"]
        for item in items
        if item.get("type") == "position"
    )

    pay_type = {0: "cash", 1: "electronically", 2: "credit"}.get(payment, "cash")

    return {
        "type": "sellReturn" if sell_return else "sell",
        "taxationType": "usnIncome",
        "operator": {"name": "Емельянов Алексей Андреевич"},
        "items": items,
        "payments": [{"type": pay_type, "sum": total}],
        "total": total,
        "password": password,
    }


def mark_position_item(
    *,
    name: str,
    mark_raw: str,
    mark_accepted: bool = False,
    price: float = 50.0,
) -> dict[str, Any]:
    """Позиция с маркой для POST /print-check."""
    item: dict[str, Any] = {
        "type": "position",
        "name": name,
        "quantity": 1,
        "price": price,
        "department": 1,
        "tax": {"type": "none"},
        "paymentObject": "commodity",
        "paymentMethod": "fullPayment",
        "mark": encode_mark_base64(mark_raw),
        "permission": {
            "uuid": "00000000-0000-0000-0000-000000000001",
            "time": "2026-07-05T10:00:00",
        },
    }
    if mark_accepted:
        item["markAccepted"] = True
    return item


def sample_receipt_mark_only(
    *,
    password: int = 30,
    mark_raw: str = DEFAULT_MARK_RAW,
    mark_accepted: bool = False,
    sell_return: bool = False,
    with_plain_item: bool = True,
) -> dict[str, Any]:
    """Чек с одной маркированной позицией (ленивый клиент: markAccepted по умолчанию false)."""
    items: list[dict[str, Any]] = []
    if with_plain_item:
        items.append(
            {
                "type": "position",
                "name": "Товар без марки",
                "quantity": 1,
                "price": 100.0,
                "department": 1,
                "tax": {"type": "none"},
                "paymentObject": "commodity",
                "paymentMethod": "fullPayment",
            }
        )
    items.append(
        mark_position_item(
            name="Маркированный товар",
            mark_raw=mark_raw,
            mark_accepted=mark_accepted,
        )
    )
    total = sum(
        item["price"] * item["quantity"]
        for item in items
        if item.get("type") == "position"
    )
    return {
        "type": "sellReturn" if sell_return else "sell",
        "taxationType": "usnIncome",
        "operator": {"name": "Емельянов Алексей Андреевич"},
        "items": items,
        "payments": [{"type": "cash", "sum": total}],
        "total": total,
        "password": password,
    }


def sample_receipt_duplicate_mark(
    *,
    password: int = 30,
    mark_raw: str = DEFAULT_MARK_RAW,
    mark_accepted: bool = False,
) -> dict[str, Any]:
    """Чек с двумя позициями и одной и той же маркой (дедуп внутри чека)."""
    items = [
        mark_position_item(name="Маркированный товар #1", mark_raw=mark_raw, mark_accepted=mark_accepted),
        mark_position_item(name="Маркированный товар #2", mark_raw=mark_raw, mark_accepted=mark_accepted, price=75.0),
    ]
    total = sum(item["price"] * item["quantity"] for item in items)
    return {
        "type": "sell",
        "taxationType": "usnIncome",
        "operator": {"name": "Емельянов Алексей Андреевич"},
        "items": items,
        "payments": [{"type": "cash", "sum": total}],
        "total": total,
        "password": password,
    }


def check_mark_response_cached(resp: HttpResponse) -> bool:
    """True, если сервер вернул марку из кэша текущего чека (description OK (cached))."""
    if not resp.json:
        return False
    marks = resp.json.get("marks")
    if isinstance(marks, list):
        for mark in marks:
            if isinstance(mark, dict) and mark.get("description") == "OK (cached)":
                return True
    return False


def check_mark_response_all_accepted(resp: HttpResponse) -> bool:
    if not resp.json:
        return False
    if resp.json.get("allAccepted") is True:
        return True
    marks = resp.json.get("marks")
    if isinstance(marks, list) and marks:
        return all(isinstance(m, dict) and m.get("accepted") is True for m in marks)
    return resp.ok


def run_check_mark_sync(
    client: KktServerClient,
    *,
    marks_raw: list[str],
    label: str,
) -> tuple[HttpResponse, float]:
    """POST /check-marks (sync), возвращает ответ и длительность HTTP."""
    payload = sample_check_mark_payload(marks_raw=marks_raw, async_mode=False)
    started = time.time()
    resp = client.check_marks(payload)
    elapsed = time.time() - started
    print_response(label, resp)
    print(f"  Время HTTP: {fmt_duration(elapsed)}")
    if check_marks_response_cached(resp):
        print("  -> марка из кэша сервера (OK cached)")
    return resp, elapsed
    

def run_mark_cache_test(
    client: KktServerClient,
    *,
    password: int,
    scenario: str,
    mark_raw: str,
) -> int:
    """Тесты серверного кэша принятых марок в рамках одного чека."""
    scenarios = {
        "all": None,
        "check-then-print": _scenario_cache_check_then_print,
        "duplicate-check": _scenario_cache_duplicate_check,
        "duplicate-items": _scenario_cache_duplicate_items,
        "cancel-reset": _scenario_cache_cancel_reset,
        "lazy-full-flow": _scenario_cache_lazy_full_flow,
    }
    if scenario not in scenarios:
        raise ValueError(f"Неизвестный сценарий: {scenario}")

    print("\n" + "=" * 70)
    print("ТЕСТ КЭША ПРИНЯТЫХ МАРОК (вариант A)")
    print("Смотрите kktserver.log: «OK (cached)», «markAccepted не указан, но марка уже принята»")
    print("=" * 70)

    resp = client.info()
    print_response("GET /info (перед тестом)", resp)
    if not resp.ok:
        return 1

    to_run = [
        "check-then-print",
        "duplicate-check",
        "duplicate-items",
        "cancel-reset",
        "lazy-full-flow",
    ] if scenario == "all" else [scenario]

    failed = 0
    for name in to_run:
        print("\n" + "-" * 70)
        err = scenarios[name](client, password=password, mark_raw=mark_raw)
        failed += err

    print("\n" + "=" * 70)
    print(f"Итог mark-cache-test: сценариев с ошибками — {failed}")
    print("=" * 70)
    return 1 if failed else 0


def _scenario_cache_check_then_print(
    client: KktServerClient,
    *,
    password: int,
    mark_raw: str,
) -> int:
    """check-marks → print-check без markAccepted (ленивый клиент)."""
    print("СЦЕНАРИЙ: check-marks, затем print-check без markAccepted")
    print("  Ожидание: печать использует кэш, полный цикл FNCheckItemBarcode не повторяется.\n")

    failed = 0
    resp1, _ = run_check_mark_sync(client, mark_raw=mark_raw, label="POST /check-mark (1)")
    if not check_mark_response_all_accepted(resp1):
        failed += 1

    payload = sample_receipt_mark_only(password=password, mark_raw=mark_raw, mark_accepted=False)
    print("\nТело print-check (markAccepted не указан):")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    resp2 = client.print_check(payload)
    print_response("POST /print-check (ленивый клиент)", resp2)
    if not resp2.ok:
        failed += 1

    return failed


def _scenario_cache_duplicate_check(
    client: KktServerClient,
    *,
    password: int,
    mark_raw: str,
) -> int:
    """Два check-mark подряд — второй должен быть из кэша."""
    del password
    print("СЦЕНАРИЙ: два POST /check-mark одной марки подряд")
    print("  Ожидание: второй ответ — description OK (cached), быстрее первого.\n")

    failed = 0
    resp1, t1 = run_check_mark_sync(client, mark_raw=mark_raw, label="POST /check-mark (1, полная проверка)")
    if not check_mark_response_all_accepted(resp1):
        failed += 1
    if check_mark_response_cached(resp1):
        print("  WARN: первый check-mark не должен быть из кэша")
        failed += 1

    resp2, t2 = run_check_mark_sync(client, mark_raw=mark_raw, label="POST /check-mark (2, из кэша)")
    if not check_mark_response_all_accepted(resp2):
        failed += 1
    if not check_mark_response_cached(resp2):
        print("  ERR: второй check-mark должен быть OK (cached)")
        failed += 1
    if t2 >= t1:
        print(f"  NOTE: второй ({fmt_duration(t2)}) не быстрее первого ({fmt_duration(t1)}) — на ККТ может быть иначе")

    # Закрываем «висящий» чек после двух check-mark без print-check
    resp_cancel = client.cancel_check()
    print_response("POST /cancel-check (очистка после сценария)", resp_cancel)
    if not resp_cancel.ok:
        failed += 1

    return failed


def _scenario_cache_duplicate_items(
    client: KktServerClient,
    *,
    password: int,
    mark_raw: str,
) -> int:
    """Один print-check, две позиции с одной маркой без markAccepted."""
    print("СЦЕНАРИЙ: print-check с двумя позициями и одной маркой")
    print("  Ожидание: полный цикл только для первой позиции, вторая — из кэша.\n")

    payload = sample_receipt_duplicate_mark(password=password, mark_raw=mark_raw, mark_accepted=False)
    print("Тело print-check:")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    resp = client.print_check(payload)
    print_response("POST /print-check (duplicate mark in items[])", resp)
    return 0 if resp.ok else 1


def _scenario_cache_cancel_reset(
    client: KktServerClient,
    *,
    password: int,
    mark_raw: str,
) -> int:
    """check-mark → cancel-check → check-mark — кэш сброшен, второй не cached."""
    del password
    print("СЦЕНАРИЙ: check-mark → cancel-check → check-mark")
    print("  Ожидание: после cancel второй check-mark снова полная проверка (не cached).\n")

    failed = 0
    resp1, _ = run_check_mark_sync(client, mark_raw=mark_raw, label="POST /check-mark (до cancel)")
    if not check_mark_response_all_accepted(resp1):
        failed += 1

    resp_cancel = client.cancel_check()
    print_response("POST /cancel-check", resp_cancel)
    if not resp_cancel.ok:
        failed += 1

    resp2, _ = run_check_mark_sync(client, mark_raw=mark_raw, label="POST /check-mark (после cancel)")
    if not check_mark_response_all_accepted(resp2):
        failed += 1
    if check_mark_response_cached(resp2):
        print("  ERR: после cancel-check марка не должна быть OK (cached)")
        failed += 1

    resp_cancel2 = client.cancel_check()
    print_response("POST /cancel-check (очистка)", resp_cancel2)
    if not resp_cancel2.ok:
        failed += 1

    return failed


def _scenario_cache_lazy_full_flow(
    client: KktServerClient,
    *,
    password: int,
    mark_raw: str,
) -> int:
    """Полный «ленивый» сценарий: check → check (cached) → print (без markAccepted) → OK."""
    print("СЦЕНАРИЙ: полный поток ленивого клиента")
    print("  check-mark → check-mark (cached) → print-check без markAccepted\n")

    failed = 0
    resp1, _ = run_check_mark_sync(client, mark_raw=mark_raw, label="1) POST /check-mark")
    if not check_mark_response_all_accepted(resp1):
        failed += 1

    resp2, _ = run_check_mark_sync(client, mark_raw=mark_raw, label="2) POST /check-mark (повтор)")
    if not check_mark_response_all_accepted(resp2):
        failed += 1
    if not check_mark_response_cached(resp2):
        print("  ERR: повторный check-mark должен быть OK (cached)")
        failed += 1

    payload = sample_receipt_mark_only(password=password, mark_raw=mark_raw, mark_accepted=False)
    resp3 = client.print_check(payload)
    print_response("3) POST /print-check (без markAccepted)", resp3)
    if not resp3.ok:
        failed += 1

    return failed


def print_response(title: str, resp: HttpResponse) -> None:
    print(f"\n=== {title} ===")
    print(f"HTTP {resp.status}")
    if resp.json is not None:
        print(json.dumps(resp.json, ensure_ascii=False, indent=2))
    else:
        print(resp.body)
    if resp.json is not None:
        if resp.ok:
            print("-> result=1 OK")
        else:
            desc = resp.json.get("description", resp.body)
            print(f"-> result=0 ERROR: {desc}")


def encode_mark_base64(mark_raw: str) -> str:
    """Кодирует марку (строка с GS1-разделителями) в base64 для API."""
    return base64.b64encode(mark_raw.encode("latin-1")).decode("ascii")


def sample_check_mark_payload(
    *,
    marks_raw: list[str] | None = None,
    sell_return: bool = False,
    async_mode: bool = False,
    cashier_name: str = "",
) -> dict[str, Any]:
    if marks_raw is None:
        marks_raw = [DEFAULT_MARK_RAW]

    marks_b64 = [encode_mark_base64(m) for m in marks_raw]
    payload: dict[str, Any] = {
        "type": "sellReturn" if sell_return else "sell",
        "async": async_mode,
    }
    if cashier_name:
        payload["cashierName"] = cashier_name
    if len(marks_b64) == 1:
        payload["mark"] = marks_b64[0]
    else:
        payload["marks"] = marks_b64
    return payload


def wait_async_check_mark(client: KktServerClient, task_id: str, timeout: int = 180) -> HttpResponse:
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp = client.check_mark_status(task_id)
        if resp.json is None:
            return resp
        status = resp.json.get("status")
        if status in ("completed", "error"):
            return resp
        time.sleep(0.5)
    raise TimeoutError(f"Проверка марки taskId={task_id} не завершилась за {timeout} сек")


def fmt_ts(t: float | None = None) -> str:
    if t is None:
        t = time.time()
    lt = time.localtime(t)
    ms = int((t - int(t)) * 1000)
    return time.strftime("%H:%M:%S", lt) + f".{ms:03d}"


def fmt_duration(seconds: float) -> str:
    if seconds < 1:
        return f"{seconds * 1000:.0f} мс"
    return f"{seconds:.2f} с"


@dataclass
class StepTiming:
    label: str
    started_at: float
    http_done_at: float
    finished_at: float | None = None
    http_resp: HttpResponse | None = None
    final_resp: HttpResponse | None = None
    task_id: str | None = None
    thread: str = field(default_factory=lambda: threading.current_thread().name)

    @property
    def http_elapsed(self) -> float:
        return self.http_done_at - self.started_at

    @property
    def total_elapsed(self) -> float | None:
        if self.finished_at is None:
            return None
        return self.finished_at - self.started_at


def print_timing_row(step: StepTiming) -> None:
    http_part = f"HTTP {fmt_duration(step.http_elapsed)}"
    if step.task_id:
        http_part += f", taskId={step.task_id[:8]}..."
    total = step.total_elapsed
    total_part = f", полное {fmt_duration(total)}" if total is not None else ""
    ok = step.final_resp.ok if step.final_resp else (step.http_resp.ok if step.http_resp else False)
    status = "OK" if ok else "ERR"
    print(
        f"  [{fmt_ts(step.started_at)} -> {fmt_ts(step.http_done_at)}] "
        f"{step.label} ({step.thread}): {http_part}{total_part} -> {status}"
    )


def run_timed_check_mark(
    client: KktServerClient,
    *,
    label: str,
    async_mode: bool,
    mark_raw: str,
    wait_timeout: int,
) -> StepTiming:
    timing = StepTiming(label=label, started_at=time.time(), http_done_at=0.0)
    payload = sample_check_mark_payload(marks_raw=[mark_raw], async_mode=async_mode)
    timing.http_resp = client.check_mark(payload)
    timing.http_done_at = time.time()

    if async_mode and timing.http_resp.json:
        timing.task_id = timing.http_resp.json.get("taskId")
        if timing.task_id:
            timing.final_resp = wait_async_check_mark(client, timing.task_id, wait_timeout)
    else:
        timing.final_resp = timing.http_resp

    timing.finished_at = time.time()
    return timing


def run_queue_test(
    client: KktServerClient,
    *,
    password: int,
    count: int,
    wait_timeout: int,
    scenario: str,
    mark_raw: str,
) -> int:
    """Симуляция очереди команд к ККТ: sync, async burst, mixed."""
    failed = 0
    scenarios = {
        "sync-chain": _scenario_sync_chain,
        "async-burst": _scenario_async_burst,
        "mixed": _scenario_mixed,
        "all": None,
    }
    if scenario not in scenarios:
        raise ValueError(f"Неизвестный сценарий: {scenario}")

    print("\n" + "=" * 70)
    print("ТЕСТ ОЧЕРЕДИ КОМАНД К ККТ")
    print("Ожидание: HTTP async отвечает сразу, но ККТ обрабатывает команды по одной.")
    print("=" * 70)

    resp = client.info()
    print_response("GET /info (перед тестом)", resp)
    if not resp.ok:
        return 1

    to_run = ["sync-chain", "async-burst", "mixed"] if scenario == "all" else [scenario]

    for name in to_run:
        print("\n" + "-" * 70)
        err = scenarios[name](
            client,
            password=password,
            count=count,
            wait_timeout=wait_timeout,
            mark_raw=mark_raw,
        )
        failed += err

    print("\n" + "=" * 70)
    print(f"Итог queue-test: сценариев с ошибками — {failed}")
    print("=" * 70)
    return 1 if failed else 0


def _scenario_sync_chain(
    client: KktServerClient,
    *,
    password: int,
    count: int,
    wait_timeout: int,
    mark_raw: str,
) -> int:
    del password  # unused
    print(f"СЦЕНАРИЙ 1: {count} синхронных POST /check-mark подряд (main thread)")
    print("  Каждый запрос блокирует HTTP до ответа ККТ.\n")

    failed = 0
    t0 = time.time()
    for i in range(count):
        step = run_timed_check_mark(
            client,
            label=f"sync check-mark #{i + 1}",
            async_mode=False,
            mark_raw=mark_raw,
            wait_timeout=wait_timeout,
        )
        print_timing_row(step)
        if not step.final_resp or not step.final_resp.ok:
            failed += 1
    print(f"\n  Вся цепочка: {fmt_duration(time.time() - t0)}")
    return failed


def _scenario_async_burst(
    client: KktServerClient,
    *,
    password: int,
    count: int,
    wait_timeout: int,
    mark_raw: str,
) -> int:
    del password
    print(f"СЦЕНАРИЙ 2: {count} async POST /check-mark почти одновременно")
    print("  HTTP должен ответить быстро; завершение на ККТ — по очереди.\n")

    def worker(idx: int) -> StepTiming:
        return run_timed_check_mark(
            client.clone(),
            label=f"async check-mark #{idx + 1}",
            async_mode=True,
            mark_raw=mark_raw,
            wait_timeout=wait_timeout,
        )

    failed = 0
    t0 = time.time()
    steps: list[StepTiming] = []

    with ThreadPoolExecutor(max_workers=count, thread_name_prefix="async-mark") as pool:
        futures = [pool.submit(worker, i) for i in range(count)]
        for fut in as_completed(futures):
            step = fut.result()
            steps.append(step)
            print_timing_row(step)
            if not step.final_resp or not step.final_resp.ok:
                failed += 1

    steps.sort(key=lambda s: s.started_at)
    if len(steps) >= 2:
        http_spread = max(s.http_done_at for s in steps) - min(s.started_at for s in steps)
        kkt_spread = max(s.finished_at or 0 for s in steps) - min(s.started_at for s in steps)
        print(f"\n  Разброс HTTP-ответов: {fmt_duration(http_spread)}")
        print(f"  Разброс полного завершения (ККТ): {fmt_duration(kkt_spread)}")

    print(f"  Весь сценарий: {fmt_duration(time.time() - t0)}")
    return failed


def _scenario_mixed(
    client: KktServerClient,
    *,
    password: int,
    count: int,
    wait_timeout: int,
    mark_raw: str,
) -> int:
    async_count = max(2, count // 2)
    print(
        f"СЦЕНАРИЙ 3: {async_count} async check-mark + sync check-mark + print-check"
    )
    print("  Sync-команды должны ждать освобождения ККТ от async-очереди.\n")

    failed = 0
    barrier = threading.Barrier(async_count + 1)

    def async_worker(idx: int) -> StepTiming:
        thread_client = client.clone()
        timing = StepTiming(
            label=f"async check-mark #{idx + 1}",
            started_at=0.0,
            http_done_at=0.0,
        )
        barrier.wait()
        timing.started_at = time.time()
        payload = sample_check_mark_payload(marks_raw=[mark_raw], async_mode=True)
        timing.http_resp = thread_client.check_mark(payload)
        timing.http_done_at = time.time()
        if timing.http_resp.json:
            timing.task_id = timing.http_resp.json.get("taskId")
        return timing

    t0 = time.time()
    async_steps: list[StepTiming] = []

    with ThreadPoolExecutor(max_workers=async_count, thread_name_prefix="mixed-async") as pool:
        futures = [pool.submit(async_worker, i) for i in range(async_count)]
        barrier.wait()

        print(f"  [{fmt_ts()}] Запуск {async_count} async + немедленно sync команды...\n")

        sync_mark = run_timed_check_mark(
            client,
            label="sync check-mark (после burst async)",
            async_mode=False,
            mark_raw=mark_raw,
            wait_timeout=wait_timeout,
        )
        print_timing_row(sync_mark)
        if not sync_mark.final_resp or not sync_mark.final_resp.ok:
            failed += 1

        print_start = time.time()
        print_resp = client.print_check(sample_receipt(password=password, with_marking=False))
        print_done = time.time()
        print_step = StepTiming(
            label="sync print-check (пока async ещё в очереди?)",
            started_at=print_start,
            http_done_at=print_done,
            finished_at=print_done,
            http_resp=print_resp,
            final_resp=print_resp,
        )
        print_timing_row(print_step)
        if not print_resp.ok:
            failed += 1

        for fut in as_completed(futures):
            async_steps.append(fut.result())

    async_steps.sort(key=lambda s: s.started_at)
    for step in async_steps:
        if step.task_id:
            step.final_resp = wait_async_check_mark(client, step.task_id, wait_timeout)
            step.finished_at = time.time()
            print_timing_row(step)
            if not step.final_resp.ok:
                failed += 1

    print(f"\n  Весь сценарий: {fmt_duration(time.time() - t0)}")
    return failed


def run_smoke_test(client: KktServerClient, password: int, with_marking: bool) -> int:
    """Последовательная проверка всех основных endpoints."""
    steps: list[tuple[str, HttpResponse]] = []

    steps.append(("GET /health", client.health()))
    steps.append(("GET /info", client.info()))
    steps.append(
        (
            "POST /print-check",
            client.print_check(sample_receipt(password=password, with_marking=with_marking)),
        )
    )
    steps.append(("POST /x-report", client.x_report(password)))
    steps.append(("POST /cancel-check", client.cancel_check(password)))
    steps.append(("POST /close-shift", client.close_shift(password)))
    steps.append(("POST /disconnect", client.disconnect()))

    failed = 0
    for title, resp in steps:
        print_response(title, resp)
        if not resp.ok:
            failed += 1

    print("\n=== Итог ===")
    print(f"Шагов: {len(steps)}, ошибок: {failed}")
    return 1 if failed else 0


def load_json_file(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("JSON должен быть объектом верхнего уровня")
    return data


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Эмулятор HTTP-клиента для Delphi KKT-сервера",
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Хост (по умолчанию {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Порт (по умолчанию {DEFAULT_PORT})")
    parser.add_argument("--password", type=int, default=30, help="Пароль ККТ для POST-команд")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="Таймаут HTTP, сек")

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("health", help="GET /health — проверка доступности сервера")
    sub.add_parser("info", help="GET /info — информация о ККТ")

    print_cmd = sub.add_parser("print-check", help="POST /print-check — печать чека")
    print_cmd.add_argument("--json", help="Путь к JSON-файлу чека")
    print_cmd.add_argument("--with-marking", action="store_true", help="Добавить маркированную позицию")
    print_cmd.add_argument(
        "--mark-only",
        action="store_true",
        help="Чек только с маркированной позицией (удобно после /check-mark)",
    )
    print_cmd.add_argument(
        "--duplicate-mark",
        action="store_true",
        help="Две позиции с одной маркой (тест дедупа в items[])",
    )
    print_cmd.add_argument(
        "--mark",
        default=DEFAULT_MARK_RAW,
        help="Марка для --with-marking / --mark-only / --duplicate-mark",
    )
    print_cmd.add_argument(
        "--mark-accepted",
        action="store_true",
        help="Для маркированной позиции: markAccepted=true (только FNSendItemBarcode)",
    )
    print_cmd.add_argument(
        "--sell-return",
        action="store_true",
        help="Чек возврата: type=sellReturn (CheckType=2)",
    )

    sub.add_parser("close-shift", help="POST /close-shift — закрытие смены (Z-отчёт)")
    sub.add_parser("x-report", help="POST /x-report — X-отчёт без гашения")
    sub.add_parser("cancel-check", help="POST /cancel-check — отмена открытого чека")
    sub.add_parser("disconnect", help="POST /disconnect — отключение от ККТ")

    check_mark = sub.add_parser("check-mark", help="POST /check-mark — проверка марки(ок)")
    check_mark.add_argument("--mark", help="Марка в открытом виде (будет закодирована в base64)")
    check_mark.add_argument("--mark-b64", help="Марка уже в base64")
    check_mark.add_argument(
        "--sell-return",
        action="store_true",
        help="Возврат: type=sellReturn (ItemStatus=3)",
    )
    check_mark.add_argument("--async", dest="async_mode", action="store_true", help="Асинхронная проверка")
    check_mark.add_argument("--cashier", default="", help="Имя кассира при открытии смены")
    check_mark.add_argument("--wait", type=int, default=180, help="Таймаут ожидания async, сек")

    check_status = sub.add_parser("check-mark-status", help="GET /check-mark/status — статус async-задачи")
    check_status.add_argument("task_id", help="taskId из POST /check-mark")

    smoke = sub.add_parser("smoke", help="Полный прогон всех endpoints")
    smoke.add_argument("--with-marking", action="store_true", help="Печатать чек с маркой")

    queue_test = sub.add_parser(
        "queue-test",
        help="Тест очереди команд: sync/async check-mark и print-check",
    )
    queue_test.add_argument(
        "--scenario",
        choices=["all", "sync-chain", "async-burst", "mixed"],
        default="all",
        help="Сценарий (по умолчанию all — все три подряд)",
    )
    queue_test.add_argument(
        "--count",
        type=int,
        default=3,
        help="Число повторов в сценарии (по умолчанию 3)",
    )
    queue_test.add_argument(
        "--mark",
        default=DEFAULT_MARK_RAW,
        help="Тестовая марка (будет закодирована в base64)",
    )
    queue_test.add_argument(
        "--wait",
        type=int,
        default=180,
        help="Таймаут ожидания async-задач, сек",
    )

    mark_cache = sub.add_parser(
        "mark-cache-test",
        help="Тест кэша принятых марок: ленивый клиент, дедуп, cancel-reset",
    )
    mark_cache.add_argument(
        "--scenario",
        choices=[
            "all",
            "check-then-print",
            "duplicate-check",
            "duplicate-items",
            "cancel-reset",
            "lazy-full-flow",
        ],
        default="all",
        help="Сценарий (по умолчанию all — все подряд)",
    )
    mark_cache.add_argument(
        "--mark",
        default=DEFAULT_MARK_RAW,
        help="Тестовая марка (будет закодирована в base64)",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    client = KktServerClient(host=args.host, port=args.port, timeout=args.timeout)

    try:
        if args.command == "health":
            resp = client.health()
            print_response("GET /health", resp)
            return 0 if resp.ok else 1

        if args.command == "info":
            print_response("GET /info", client.info())
            return 0

        if args.command == "print-check":
            if args.json:
                payload = load_json_file(args.json)
            elif args.duplicate_mark:
                payload = sample_receipt_duplicate_mark(
                    password=args.password,
                    mark_raw=args.mark,
                    mark_accepted=args.mark_accepted,
                )
            elif args.mark_only:
                payload = sample_receipt_mark_only(
                    password=args.password,
                    mark_raw=args.mark,
                    mark_accepted=args.mark_accepted,
                    sell_return=args.sell_return,
                )
            else:
                payload = sample_receipt(
                    password=args.password,
                    with_marking=args.with_marking,
                    mark_accepted=args.mark_accepted,
                    sell_return=args.sell_return,
                    mark_raw=args.mark,
                )
            print("Тело запроса:")
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            resp = client.print_check(payload)
            print_response("POST /print-check", resp)
            return 0 if resp.ok else 1

        if args.command == "close-shift":
            resp = client.close_shift(args.password)
            print_response("POST /close-shift", resp)
            return 0 if resp.ok else 1

        if args.command == "x-report":
            resp = client.x_report(args.password)
            print_response("POST /x-report", resp)
            return 0 if resp.ok else 1

        if args.command == "cancel-check":
            resp = client.cancel_check(args.password)
            print_response("POST /cancel-check", resp)
            return 0 if resp.ok else 1

        if args.command == "disconnect":
            resp = client.disconnect()
            print_response("POST /disconnect", resp)
            return 0 if resp.ok else 1

        if args.command == "check-mark":
            if args.mark_b64:
                payload: dict[str, Any] = {
                    "type": "sellReturn" if args.sell_return else "sell",
                    "async": args.async_mode,
                    "mark": args.mark_b64,
                }
                if args.cashier:
                    payload["cashierName"] = args.cashier
            elif args.mark:
                payload = sample_check_mark_payload(
                    marks_raw=[args.mark],
                    sell_return=args.sell_return,
                    async_mode=args.async_mode,
                    cashier_name=args.cashier,
                )
            else:
                payload = sample_check_mark_payload(
                    sell_return=args.sell_return,
                    async_mode=args.async_mode,
                    cashier_name=args.cashier,
                )
            print("Тело запроса:")
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            resp = client.check_mark(payload)
            print_response("POST /check-mark", resp)
            if resp.ok and args.async_mode and resp.json and resp.json.get("taskId"):
                print(f"\nОжидание async taskId={resp.json['taskId']} ...")
                resp = wait_async_check_mark(client, resp.json["taskId"], args.wait)
                print_response("GET /check-mark/status (completed)", resp)
            return 0 if resp.ok else 1

        if args.command == "check-mark-status":
            resp = client.check_mark_status(args.task_id)
            print_response("GET /check-mark/status", resp)
            return 0 if resp.ok else 1

        if args.command == "smoke":
            return run_smoke_test(client, args.password, args.with_marking)

        if args.command == "queue-test":
            return run_queue_test(
                client,
                password=args.password,
                count=args.count,
                wait_timeout=args.wait,
                scenario=args.scenario,
                mark_raw=args.mark,
            )

        if args.command == "mark-cache-test":
            return run_mark_cache_test(
                client,
                password=args.password,
                scenario=args.scenario,
                mark_raw=args.mark,
            )

    except (ConnectionError, OSError, ValueError, TimeoutError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1

    parser.error(f"Неизвестная команда: {args.command}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

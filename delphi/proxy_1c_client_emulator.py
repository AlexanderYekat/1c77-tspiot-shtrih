#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Эмулятор HTTP-клиента 1С 7.7 через proxy (cto_csharp_proxyfmu, :2579).

Повторяет вызовы из permissive_regime_2024:
  POST /document              — разрешительный режим (FMU)
  GET/POST /kkt/...           — команды ККТ (Delphi kktserverindy)

Примеры:
  python proxy_1c_client_emulator.py health
  python proxy_1c_client_emulator.py kkt-health
  python proxy_1c_client_emulator.py smoke
  python proxy_1c_client_emulator.py document
  python proxy_1c_client_emulator.py document --json rr.json
  python proxy_1c_client_emulator.py kkt-info
  python proxy_1c_client_emulator.py kkt-print-check
  python proxy_1c_client_emulator.py kkt-check-mark --mark "010460406000301021N4N57RDCUDVTL"
  python proxy_1c_client_emulator.py kkt-check-mark-status TASK_ID
  python proxy_1c_client_emulator.py kkt-close-shift
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# Переиспользуем тестовые данные и печать ответов из эмулятора Delphi-клиента.
from kkt_client_emulator import (
    DEFAULT_MARK_RAW,
    DEFAULT_TIMEOUT,
    HttpResponse,
    encode_mark_base64,
    fmt_duration,
    load_json_file,
    print_response,
    sample_check_mark_payload,
    sample_receipt,
    wait_async_check_mark,
)


DEFAULT_PROXY_HOST = "127.0.0.1"
DEFAULT_PROXY_PORT = 2579
DEFAULT_INN = "504706636254"
DEFAULT_FN = "0456010012345654"
DEFAULT_MARK_RR = (
    "0102900252571014215IpSKllaSsfid91EE09926R1lOzfbXqNubd0wR7qnoxBaPgny/aGSACodTm6zRak="
)


class Proxy1CClient:
    """Клиент как V7HttpReader в 1С: /document и /kkt/* через proxy."""

    def __init__(
        self,
        host: str = DEFAULT_PROXY_HOST,
        port: int = DEFAULT_PROXY_PORT,
        timeout: int = DEFAULT_TIMEOUT,
    ) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.base_url = f"http://{host}:{port}"

    def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | str | None = None,
        *,
        like_1c_document: bool = False,
        like_1c_kkt: bool = False,
    ) -> HttpResponse:
        if not path.startswith("/"):
            path = "/" + path

        url = f"{self.base_url}{path}"
        data: bytes | None = None
        headers: dict[str, str] = {}

        if body is not None:
            if isinstance(body, dict):
                text = json.dumps(body, ensure_ascii=False)
            else:
                text = body
            data = text.encode("utf-8")

        if like_1c_document:
            # ОтправитьМаркуНаПроверку: только Content-Type без charset.
            if data is not None:
                headers["Content-Type"] = "application/json"
        elif like_1c_kkt or data is not None:
            # HTTPЗапросКПрокси: Content-Type + Accept.
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"
        elif method.upper() == "GET" and like_1c_kkt:
            headers["Accept"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            status = exc.code
        except urllib.error.URLError as exc:
            raise ConnectionError(
                f"Не удалось подключиться к proxy {url}: {exc.reason}. "
                "Запустите cto_csharp_proxyfmu на порту 2579."
            ) from exc

        parsed: dict[str, Any] | None
        try:
            parsed = json.loads(raw) if raw.strip() else None
        except json.JSONDecodeError:
            parsed = None

        return HttpResponse(status=status, body=raw, json=parsed)

    def health(self) -> HttpResponse:
        return self._request("GET", "/health")

    def document(self, payload: dict[str, Any] | str) -> HttpResponse:
        return self._request("POST", "/document", payload, like_1c_document=True)

    def kkt_get(self, api_path: str) -> HttpResponse:
        return self._request("GET", self.kkt_path(api_path), like_1c_kkt=True)

    def kkt_post(self, api_path: str, payload: dict[str, Any] | None = None) -> HttpResponse:
        body = payload if payload is not None else {}
        return self._request("POST", self.kkt_path(api_path), body, like_1c_kkt=True)

    @staticmethod
    def kkt_path(api_path: str) -> str:
        api_path = api_path.strip()
        if not api_path.startswith("/"):
            api_path = "/" + api_path
        return "/kkt" + api_path


def sample_document_json(
    *,
    inn: str = DEFAULT_INN,
    fn: str = DEFAULT_FN,
    mark_raw: str = DEFAULT_MARK_RR,
) -> dict[str, Any]:
    """JSON как сформироватьJSON() для POST /document."""
    payload: dict[str, Any] = {
        "action": "check",
        "type": "receipt",
        "positions": [
            {
                "organization": {"inn": inn},
                "marking_codes": [encode_mark_base64(mark_raw)],
            }
        ],
    }
    if fn:
        payload["shift"] = fn
    return payload


def print_health_response(title: str, resp: HttpResponse) -> None:
    print(f"\n=== {title} ===")
    print(f"HTTP {resp.status}")
    if resp.json is not None:
        print(json.dumps(resp.json, ensure_ascii=False, indent=2))
    else:
        print(resp.body)

    if resp.status != 200:
        print("-> proxy недоступен (служба C# не отвечает)")
        return

    if resp.json is None:
        print("-> HTTP 200, но тело не JSON")
        return

    kkt = resp.json.get("kkt") or {}
    fmu = resp.json.get("fmu") or {}
    proxy_version = resp.json.get("version")
    if proxy_version:
        print(f"-> Proxy C#: version={proxy_version}")

    if kkt.get("reachable"):
        kkt_version = kkt.get("version")
        suffix = f" (version={kkt_version})" if kkt_version else ""
        print(f"-> Delphi KKT: доступен{suffix}")
    else:
        err = kkt.get("error", "нет ответа")
        print(f"-> Delphi KKT: недоступен — {err}")

    if fmu.get("reachable"):
        print("-> FMU: порт открыт")
    else:
        err = fmu.get("error", "нет ответа")
        print(f"-> FMU: недоступен — {err}")


def print_document_response(title: str, resp: HttpResponse) -> None:
    print(f"\n=== {title} ===")
    print(f"HTTP {resp.status}")
    if resp.json is not None:
        print(json.dumps(resp.json, ensure_ascii=False, indent=2))
    else:
        print(resp.body)

    if resp.status != 200:
        print(f"-> ошибка HTTP {resp.status} (как в 1С: кодОшибки=20)")
        return

    if resp.json is None:
        print("-> HTTP 200, но тело не JSON")
        return

    code = resp.json.get("Code", resp.json.get("code"))
    if code is not None:
        print(f"-> FMU code={code}")
        if str(code) in ("0", "1"):
            req_id = resp.json.get("reqId", resp.json.get("reqid", ""))
            ts = resp.json.get("reqTimestamp", resp.json.get("reqtimestamp", ""))
            if req_id or ts:
                print(f"-> UUID={req_id}, time={ts}")
    else:
        print("-> HTTP 200, поле Code не найдено в ответе FMU")


def run_smoke(client: Proxy1CClient, *, with_marking: bool) -> int:
    failed = 0

    print("\n" + "=" * 70)
    print("SMOKE: эмулятор клиента 1С через proxy")
    print(f"Proxy: {client.base_url}")
    print("=" * 70)

    started = time.time()
    resp = client.health()
    print_health_response("GET /health (служба C# + проверка Delphi и FMU)", resp)
    if resp.status != 200:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    started = time.time()
    resp = client.kkt_get("/health")
    print_response("GET /kkt/health (напрямую через proxy → Delphi)", resp)
    if resp.status != 200:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    started = time.time()
    resp = client.document(sample_document_json())
    print_document_response("POST /document (разрешительный режим)", resp)
    if resp.status != 200:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    started = time.time()
    resp = client.kkt_get("/info")
    print_response("GET /kkt/info", resp)
    if resp.status != 200:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    payload = sample_receipt(with_marking=with_marking)
    started = time.time()
    resp = client.kkt_post("/print-check", payload)
    print_response("POST /kkt/print-check", resp)
    if resp.status != 200 or not resp.ok:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    started = time.time()
    resp = client.kkt_post("/check-marks", sample_check_mark_payload(async_mode=False))
    print_response("POST /kkt/check-marks", resp)
    if resp.status != 200 or not resp.ok:
        failed += 1
    print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    for title, path in (
        ("POST /kkt/x-report", "/x-report"),
        ("POST /kkt/cancel-check", "/cancel-check"),
        ("POST /kkt/close-shift", "/close-shift"),
    ):
        started = time.time()
        resp = client.kkt_post(path, {})
        print_response(title, resp)
        if resp.status != 200 or not resp.ok:
            failed += 1
        print(f"  Время HTTP: {fmt_duration(time.time() - started)}")

    print("\n" + "=" * 70)
    print(f"Итог smoke: ошибок — {failed}")
    print("Подсказка: GET /health — proxy C#; kkt.reachable=false — Delphi; fmu.reachable=false — FMU.")
    print("Подсказка: 500 на /kkt/* нормален, если Delphi KKT-сервер не запущен.")
    print("Ошибка на /document — проверьте FMU на :2578 и Content-Type в proxy.")
    print("=" * 70)
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Эмулятор HTTP-клиента 1С 7.7 через proxy (:2579)",
    )
    parser.add_argument("--host", default=DEFAULT_PROXY_HOST, help="Хост proxy")
    parser.add_argument("--port", type=int, default=DEFAULT_PROXY_PORT, help="Порт proxy")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="Таймаут HTTP, сек")
    parser.add_argument("--inn", default=DEFAULT_INN, help="ИНН для /document")
    parser.add_argument("--fn", default=DEFAULT_FN, help="Номер ФН для /document")
    parser.add_argument(
        "--mark",
        default=DEFAULT_MARK_RR,
        help="Марка для /document и /kkt/check-mark",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("health", help="GET /health — служба C# и доступность Delphi/FMU")
    sub.add_parser("kkt-health", help="GET /kkt/health — health Delphi через proxy")

    smoke = sub.add_parser("smoke", help="Прогон /document и основных /kkt/*")
    smoke.add_argument("--with-marking", action="store_true", help="Чек с маркой")

    document = sub.add_parser("document", help="POST /document — разрешительный режим")
    document.add_argument("--json", help="Путь к JSON-файлу (иначе тестовый)")

    sub.add_parser("kkt-info", help="GET /kkt/info")

    print_check = sub.add_parser("kkt-print-check", help="POST /kkt/print-check")
    print_check.add_argument("--json", help="Путь к JSON чека")
    print_check.add_argument("--with-marking", action="store_true")

    check_marks = sub.add_parser("kkt-check-marks", help="POST /kkt/check-marks")
    check_marks.add_argument("--async", dest="async_mode", action="store_true")
    check_marks.add_argument("--cashier", default="")
    check_marks.add_argument("--wait", type=int, default=180)
    check_marks.add_argument("--mark", default="")

    status = sub.add_parser("kkt-check-marks-status", help="GET /kkt/check-marks/status")
    status.add_argument("task_id", help="ID задания")

    sub.add_parser("kkt-close-shift", help="POST /kkt/close-shift")
    sub.add_parser("kkt-x-report", help="POST /kkt/x-report")
    sub.add_parser("kkt-cancel-check", help="POST /kkt/cancel-check")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    client = Proxy1CClient(host=args.host, port=args.port, timeout=args.timeout)

    try:
        if args.command == "health":
            resp = client.health()
            print_health_response("GET /health", resp)
            return 0 if resp.status == 200 else 1

        if args.command == "kkt-health":
            resp = client.kkt_get("/health")
            print_response("GET /kkt/health", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "smoke":
            return run_smoke(client, with_marking=args.with_marking)

        if args.command == "document":
            payload: dict[str, Any]
            if args.json:
                payload = load_json_file(args.json)
            else:
                payload = sample_document_json(inn=args.inn, fn=args.fn, mark_raw=args.mark)
            resp = client.document(payload)
            print_document_response("POST /document", resp)
            return 0 if resp.status == 200 else 1

        if args.command == "kkt-info":
            resp = client.kkt_get("/info")
            print_response("GET /kkt/info", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "kkt-print-check":
            if args.json:
                payload = load_json_file(args.json)
            else:
                payload = sample_receipt(with_marking=args.with_marking, mark_raw=args.mark)
            resp = client.kkt_post("/print-check", payload)
            print_response("POST /kkt/print-check", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "kkt-check-marks":
            payload = sample_check_mark_payload(
                marks_raw=[args.mark],
                async_mode=args.async_mode,
                cashier_name=args.cashier,
            )
            resp = client.kkt_post("/check-marks", payload)
            print_response("POST /kkt/check-marks", resp)
            if resp.status != 200 or not resp.ok:
                return 1
            if args.async_mode and resp.json and resp.json.get("taskId"):
                task_id = str(resp.json["taskId"])
                print(f"\nОжидание async taskId={task_id} ...")
                final = wait_async_check_mark(
                    _KktStatusClient(client),
                    task_id,
                    timeout=args.wait,
                )
                print_response("GET /kkt/check-marks/status", final)
                return 0 if final.ok else 1
            return 0

        if args.command == "kkt-check-marks-status":
            query = urllib.parse.urlencode({"taskId": args.task_id})
            resp = client.kkt_get(f"/check-marks/status?{query}")
            print_response("GET /kkt/check-marks/status", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "kkt-close-shift":
            resp = client.kkt_post("/close-shift", {})
            print_response("POST /kkt/close-shift", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "kkt-x-report":
            resp = client.kkt_post("/x-report", {})
            print_response("POST /kkt/x-report", resp)
            return 0 if resp.status == 200 and resp.ok else 1

        if args.command == "kkt-cancel-check":
            resp = client.kkt_post("/cancel-check", {})
            print_response("POST /kkt/cancel-check", resp)
            return 0 if resp.status == 200 and resp.ok else 1

    except (ConnectionError, TimeoutError, ValueError, OSError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1

    raise RuntimeError(f"Неизвестная команда: {args.command}")


class _KktStatusClient:
    """Адаптер для wait_async_check_mark из kkt_client_emulator."""

    def __init__(self, proxy_client: Proxy1CClient) -> None:
        self._proxy = proxy_client

    def check_mark_status(self, task_id: str) -> HttpResponse:
        query = urllib.parse.urlencode({"taskId": task_id})
        return self._proxy.kkt_get(f"/check-marks/status?{query}")


if __name__ == "__main__":
    raise SystemExit(main())

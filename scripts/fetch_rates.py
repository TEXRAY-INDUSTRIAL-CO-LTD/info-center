# -*- coding: utf-8 -*-
"""
匯率積木 — 抓取器
資料源:臺灣銀行牌告匯率(透過 FinMind 開放 API,dataset=TaiwanExchangeRate)
輸出:data/rates.json

台銀牌告有四個價:現金買入/現金賣出/即期買入/即期賣出。
部分幣別台銀不掛某一類(例:南非幣無現金價、越南盾無即期價),API 會回 0,
本程式一律轉成 None,前端顯示為「—」,不可顯示 0。
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

API = "https://api.finmindtrade.com/api/v4/data"
DATASET = "TaiwanExchangeRate"
UA = {"User-Agent": "texray-info-center/1.0 (+https://github.com/TEXRAY-INDUSTRIAL-CO-LTD)"}

# 顯示順序即此順序
CURRENCIES = [
    ("USD", "美元"),
    ("CNY", "人民幣"),
    ("JPY", "日圓"),
    ("EUR", "歐元"),
    ("VND", "越南盾"),
    ("ZAR", "南非幣"),
]

# 主顯示價格:現金賣出;台銀未掛現金的幣別退回即期賣出
PRIMARY_PREFERENCE = ["cash_sell", "spot_sell"]
FIELD_LABEL = {
    "cash_buy": "現金買入",
    "cash_sell": "現金賣出",
    "spot_buy": "即期買入",
    "spot_sell": "即期賣出",
}

HISTORY_DAYS = 400          # 抓一年多,前端可切 30/90/365 天
OUT = Path(__file__).resolve().parents[1] / "data" / "rates.json"
TPE = timezone(timedelta(hours=8))


def fetch(currency: str, start_date: str, retries: int = 3) -> list[dict]:
    """向 FinMind 取單一幣別的牌告歷史。失敗會重試。"""
    url = API + "?" + urllib.parse.urlencode(
        {"dataset": DATASET, "data_id": currency, "start_date": start_date}
    )
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.loads(resp.read())
            if payload.get("status") != 200:
                raise RuntimeError(f"API 回應非 200:{payload.get('msg')}")
            return payload.get("data") or []
        except Exception as err:                      # noqa: BLE001 — 抓取器要能容錯重試
            last_err = err
            print(f"  [{currency}] 第 {attempt} 次失敗:{type(err).__name__}: {err}", file=sys.stderr)
            if attempt < retries:
                time.sleep(2 * attempt)
    raise RuntimeError(f"{currency} 抓取失敗:{last_err}")


def clean(value) -> float | None:
    """台銀未掛牌的價格 API 回 0,轉成 None。"""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


def build_currency(code: str, name: str, rows: list[dict]) -> dict:
    rows = sorted(rows, key=lambda r: r["date"])
    cleaned = [
        {
            "date": r["date"],
            "cash_buy": clean(r.get("cash_buy")),
            "cash_sell": clean(r.get("cash_sell")),
            "spot_buy": clean(r.get("spot_buy")),
            "spot_sell": clean(r.get("spot_sell")),
        }
        for r in rows
    ]
    if not cleaned:
        raise RuntimeError(f"{code} 無資料")

    latest = cleaned[-1]

    # 決定主顯示欄位:優先現金賣出,沒掛牌就退回即期賣出
    primary_field = next((f for f in PRIMARY_PREFERENCE if latest.get(f) is not None), None)
    if primary_field is None:
        raise RuntimeError(f"{code} 現金與即期賣出價皆無")

    # 走勢序列:只取主顯示欄位有值的日期
    history = [[r["date"], r[primary_field]] for r in cleaned if r[primary_field] is not None]

    prev = history[-2][1] if len(history) >= 2 else None
    current = history[-1][1]
    change = round(current - prev, 6) if prev is not None else None
    change_pct = round((current - prev) / prev * 100, 4) if prev else None

    return {
        "code": code,
        "name": name,
        "date": latest["date"],
        "cash_buy": latest["cash_buy"],
        "cash_sell": latest["cash_sell"],
        "spot_buy": latest["spot_buy"],
        "spot_sell": latest["spot_sell"],
        "primary_field": primary_field,
        "primary_label": FIELD_LABEL[primary_field],
        "primary": current,
        "prev": prev,
        "change": change,
        "change_pct": change_pct,
        "history": history,
    }


def main() -> int:
    start_date = (datetime.now(TPE) - timedelta(days=HISTORY_DAYS)).strftime("%Y-%m-%d")
    print(f"抓取臺灣銀行牌告匯率(起始日 {start_date})")

    currencies = []
    for code, name in CURRENCIES:
        rows = fetch(code, start_date)
        item = build_currency(code, name, rows)
        currencies.append(item)
        print(
            f"  {name}({code}) {item['date']} "
            f"{item['primary_label']} {item['primary']} "
            f"({item['change']:+} / {item['change_pct']:+.2f}%)"
            if item["change"] is not None
            else f"  {name}({code}) {item['date']} {item['primary_label']} {item['primary']}"
        )
        time.sleep(0.4)                                # 對 API 客氣一點

    data_date = max(c["date"] for c in currencies)
    out = {
        "block": "rates",
        "title": "臺灣銀行牌告匯率",
        "source": "臺灣銀行牌告匯率(FinMind 開放 API)",
        "source_url": "https://rate.bot.com.tw/xrt?Lang=zh-TW",
        "data_date": data_date,
        "fetched_at": datetime.now(TPE).isoformat(timespec="seconds"),
        "primary_note": "主要顯示「現金賣出」;台銀未掛現金牌價之幣別改列「即期賣出」並標註。",
        "currencies": currencies,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    size_kb = OUT.stat().st_size / 1024
    print(f"已寫入 {OUT}({size_kb:.1f} KB,資料日期 {data_date})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

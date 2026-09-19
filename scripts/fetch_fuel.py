# -*- coding: utf-8 -*-
"""
燃油附加費抓取

DHL:官網燃油費率表是伺服器端渲染在 HTML 裡(非 JS 載入),可直接解析。
     https://www.dhl.com/tw-zh/home/express/products-and-solutions/products-and-services-overview/surcharges.html
     取「第一欄為年份日期區間、第二欄為百分比」的表格,
     列如 ['2026 年 9 月 14 日至 20 日', '43.75%']。

     **不要設 User-Agent**(2026-09-17 實測,交錯測試 3/3):
       無 UA(Python-urllib 預設) → 每次成功,約 3 秒
       Chrome UA / 自訂短 UA      → 每次逾時或連線被重設
     DHL 的防護會對「宣稱是瀏覽器、但 TLS 指紋不是瀏覽器」的請求掛住不回應,
     反而放行誠實的非瀏覽器 UA。舊版曾為避開反爬蟲而加 Chrome UA,在新站是反效果。
     (FedEx 的 PDF 相反,需要 Referer 標頭才拿得到,兩邊不要互相套用。)

FedEx:官網全站對程式抓取回傳 Akamai 阻擋頁,**無法自動抓**,採人工維護
     (數值寫在 data/fuel_manual.json,由專人每週更新)。

輸出:data/fuel.json —— 這份只有兩個百分比,不含任何機密資料,
      可以放到公開的 GitHub Pages 供內部版工具跨域取用。
"""
from __future__ import annotations

import json
import re
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

URL = ("https://www.dhl.com/tw-zh/home/express/products-and-solutions/"
       "products-and-services-overview/surcharges.html")
# 刻意不含 User-Agent,原因見模組說明
HEADERS = {"Accept-Language": "zh-TW,zh;q=0.9"}

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "fuel.json"
MANUAL = ROOT / "data" / "fuel_manual.json"
TPE = timezone(timedelta(hours=8))

# 「2026 年 9 月 14 日至 20 日」(同月)與「2026 年 9 月 28 日至 10 月 4 日」(跨月)
WEEK_ROW = re.compile(
    r"^\s*(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"
    r"\s*至\s*(?:(\d{1,2})\s*月\s*)?(\d{1,2})\s*日\s*$"
)
PERCENT = re.compile(r"([\d.]+)\s*%")


def strip_tags(html: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html)).strip()


def parse_week(date_txt: str, pct_txt: str) -> dict | None:
    """一列解析成一週;格式不符回 None(呼叫端用這個判斷是不是目標表格)"""
    m = WEEK_ROW.match(date_txt)
    pm = PERCENT.search(pct_txt)
    if not (m and pm):
        return None
    year, m1, d1, m2, d2 = int(m[1]), int(m[2]), int(m[3]), m[4], int(m[5])
    m2 = int(m2) if m2 else m1
    # 跨年:12 月 28 日至 1 月 3 日 → 結束日屬次年
    end_year = year + 1 if m2 < m1 else year
    return {
        "label": date_txt,
        "start": f"{year:04d}-{m1:02d}-{d1:02d}",
        "end": f"{end_year:04d}-{m2:02d}-{d2:02d}",
        "percent": float(pm[1]),
    }


def download(attempts: int = 3) -> str:
    """
    DHL 偶爾會在回應主體傳到一半停住(約 1/5 機率,連線已建立、讀 chunked body 時逾時),
    重試一次通常就過。單次偶發卡住不值得讓整份資料停更一輪。
    """
    last = None
    for i in range(1, attempts + 1):
        try:
            req = urllib.request.Request(URL, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as err:                       # noqa: BLE001 逾時/連線重設都要重試
            last = err
            print(f"  第 {i} 次抓取失敗({type(err).__name__}),{'重試' if i < attempts else '放棄'}",
                  file=sys.stderr)
            if i < attempts:
                time.sleep(3)
    raise RuntimeError(f"DHL 頁面連續 {attempts} 次抓取失敗:{type(last).__name__}: {last}")


def fetch_dhl() -> list[dict]:
    html = download()

    # 用「資料長相」而非表頭文字辨識目標表格:同一頁還有一張油價對照表,
    # 它的表頭同樣含「附加費」,只比對表頭會抓錯表。
    for table in re.findall(r"<table.*?</table>", html, re.S):
        weeks = []
        for row in re.findall(r"<tr.*?</tr>", table, re.S):
            cells = [strip_tags(c) for c in re.findall(r"<t[dh].*?</t[dh]>", row, re.S)]
            if len(cells) < 2:
                continue
            wk = parse_week(cells[0], cells[1])
            if wk:
                weeks.append(wk)
        if weeks:
            return weeks
    raise RuntimeError("找不到 DHL 燃油費率表(頁面結構可能已改版)")


def current_week(weeks: list[dict], today: str) -> dict:
    """
    找涵蓋今天的那一週。找不到就拋錯,不做任何猜測——
    新版頁面第一列是「尚未到來」的週次(例:今天 9/17,首列是 9/28-10/4),
    舊版那種「取第一列當最新」的退路會安靜地套用未來費率,比直接失敗更糟。
    """
    for w in weeks:
        if w["start"] <= today <= w["end"]:
            return w
    span = f"{weeks[-1]['start']}~{weeks[0]['end']}" if weeks else "(空)"
    raise RuntimeError(
        f"DHL 費率表沒有涵蓋今天({today})的週次,表上區間為 {span};"
        f"可能是頁面停更或日期格式又改了"
    )


def main() -> int:
    today = datetime.now(TPE).strftime("%Y-%m-%d")
    weeks = fetch_dhl()
    cur = current_week(weeks, today)
    print(f"DHL 燃油:{cur['label']} = {cur['percent']}%(共取得 {len(weeks)} 週)")

    manual = {}
    if MANUAL.exists():
        manual = json.loads(MANUAL.read_text(encoding="utf-8"))
    fedex = manual.get("fedex", {})
    if fedex:
        print(f"FedEx 燃油(人工):{fedex.get('percent')}% "
              f"(資料日 {fedex.get('as_of')},{fedex.get('label', '')})")
    else:
        print("FedEx 燃油:尚未提供人工數值")

    out = {
        "updated_at": datetime.now(TPE).isoformat(timespec="seconds"),
        "dhl": {
            "percent": cur["percent"],
            "label": cur["label"],
            "start": cur["start"],
            "end": cur["end"],
            "source": URL,
            "auto": True,
            "history": weeks,
        },
        "fedex": {
            "percent": fedex.get("percent"),
            "label": fedex.get("label", ""),
            "as_of": fedex.get("as_of"),
            "source": "https://www.fedex.com/zh-tw/shipping/surcharges.html",
            "auto": False,
            "note": "FedEx 官網封鎖程式抓取,此數值由人工維護。",
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"已寫入 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

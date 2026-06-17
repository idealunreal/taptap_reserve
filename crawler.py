"""TapTap 游戏预约量每日爬虫.

功能:
    - 从 games.json 读取要跟踪的游戏列表 (app_id + release_date)
    - 调用 TapTap 公开 web API 抓取每个游戏当前预约量
    - 只在 [release_date - 30天, release_date] 区间内记录
    - 结果追加到 reserve.csv (date,app_id,name,reserve_count,tracked_days)
    - tracked_days: 该游戏已累计跟踪的天数 (第几天, 从 1 开始)
    - 每个 app_id 每天只写一条 (重复运行幂等覆盖当日)

使用:
    python crawler.py                # 抓取一次
    python crawler.py --once         # 同上
    可挂到 Windows 任务计划程序 / cron 每日执行一次.

依赖:
    pip install requests
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

import requests

ROOT = Path(__file__).resolve().parent
GAMES_FILE = ROOT / "games.json"   # 可选; 不存在则用下方 GAMES 写死列表
DATA_DIR = ROOT / "data"
DATA_FILE = ROOT / "reserve.csv"   # 所有游戏汇总到一个 CSV
LOG_FILE = ROOT / "crawler.log"

# 写死的跟踪列表 (2026-05-25 从 TapTap 预约榜 Top 抓取).
# release_date 为 None 表示发布日期未公布, 此时每天都采集; 公布后回看最后 30 天即可.
GAMES: list[dict] = [
    {"app_id": "740298", "name": "白日梦想屋",          "release_date": "2026-05-27"},
    {"app_id": "759688", "name": "卡厄思梦境",          "release_date": "2026-05-28"},
    {"app_id": "746164", "name": "夜幕之下",            "release_date": "2026-06-05"},
    {"app_id": "383874", "name": "无限大",              "release_date": None},
    {"app_id": "733908", "name": "失控进化",            "release_date": None},  # 首发定档 7 月
    {"app_id": "593829", "name": "蓝色星原：旅谣",      "release_date": None},
    {"app_id": "772909", "name": "粒粒的小人国",        "release_date": None},
    {"app_id": "386208", "name": "望月",                "release_date": None},
    {"app_id": "730674", "name": "异人之下",            "release_date": None},
    {"app_id": "753921", "name": "崩坏：因缘精灵",      "release_date": None},
    {"app_id": "749379", "name": "天堂2：盟约",         "release_date": None},
]

# TapTap 详情接口 (web v2). 返回里包含 stat.rating / reserve_count 等字段.
DETAIL_URL = "https://www.taptap.cn/webapiv2/app/v2/detail-by-id/{app_id}"

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0 Safari/537.36"
    ),
    "Referer": "https://www.taptap.cn/",
    # VN/VN_CODE 必填, 否则返回 INVALID_XUA
    "X-UA": "V=1&PN=WebApp&LANG=zh_CN&PLT=PC&VN=2.30.0&VN_CODE=140",
}

WINDOW_DAYS = 30
TIMEOUT = 15
RETRIES = 3
SLEEP_BETWEEN = 2.0


def _setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(LOG_FILE, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def fetch_reserve(app_id: str) -> tuple[Optional[int], Optional[str]]:
    """返回 (reserve_count, title). 失败返回 (None, None)."""
    url = DETAIL_URL.format(app_id=app_id)
    params = {"X-UA": HEADERS["X-UA"]}
    last_err: Optional[Exception] = None
    for attempt in range(1, RETRIES + 1):
        try:
            r = requests.get(url, headers=HEADERS, params=params, timeout=TIMEOUT)
            if r.status_code != 200:
                raise RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")
            payload = r.json()
            data = payload.get("data") or {}
            # 字段名可能是 reserve_count / reserved_count, 双保险
            reserve = (
                data.get("reserve_count")
                or data.get("reserved_count")
                or (data.get("stat") or {}).get("reserve_count")
            )
            title = data.get("title") or data.get("name")
            if reserve is None:
                logging.warning("[%s] 响应中未找到 reserve_count, keys=%s",
                                app_id, list(data.keys())[:20])
                return None, title
            return int(reserve), title
        except Exception as e:  # noqa: BLE001
            last_err = e
            logging.warning("[%s] 第 %d 次抓取失败: %s", app_id, attempt, e)
            time.sleep(2 * attempt)
    logging.error("[%s] 重试 %d 次仍失败: %s", app_id, RETRIES, last_err)
    return None, None


def in_window(release_date: Optional[date], today: date) -> bool:
    # 发布日未公布时始终采集; 公布后只在 [发布前30天, 发布日] 区间内采集.
    if release_date is None:
        return True
    start = release_date - timedelta(days=WINDOW_DAYS)
    return start <= today <= release_date


def _recompute_tracked_days(rows: list[dict]) -> None:
    """为每个 app_id 按日期升序回填 tracked_days (第几天跟踪, 从 1 开始)."""
    by_app: dict[str, list[dict]] = {}
    for r in rows:
        by_app.setdefault(r.get("app_id", ""), []).append(r)
    for app_rows in by_app.values():
        for i, r in enumerate(sorted(app_rows, key=lambda x: x.get("date", "")), start=1):
            r["tracked_days"] = i


def upsert_row(csv_path: Path, today: date, app_id: str, reserve: int, title: str) -> int:
    """汇总文件: 同一 (date, app_id) 重复写入则覆盖. 返回该游戏已跟踪天数."""
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["date", "app_id", "name", "reserve_count", "tracked_days"]
    rows: list[dict] = []
    if csv_path.exists():
        with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
    today_s = today.isoformat()
    rows = [r for r in rows if not (r.get("date") == today_s and r.get("app_id") == app_id)]
    rows.append({"date": today_s, "app_id": app_id, "name": title, "reserve_count": reserve})
    rows.sort(key=lambda r: (r["date"], r["app_id"]))
    _recompute_tracked_days(rows)
    with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
    for r in rows:
        if r.get("date") == today_s and r.get("app_id") == app_id:
            return int(r.get("tracked_days") or 0)
    return 0


def _load_games() -> list[dict]:
    if GAMES_FILE.exists():
        return json.loads(GAMES_FILE.read_text(encoding="utf-8"))
    return GAMES


def run_once() -> int:
    games = _load_games()
    today = datetime.now().date()
    ok = skipped = failed = 0
    for g in games:
        app_id = str(g["app_id"])
        rd_raw = g.get("release_date")
        release: Optional[date] = None
        if rd_raw:
            try:
                release = datetime.strptime(rd_raw, "%Y-%m-%d").date()
            except Exception as e:
                logging.error("[%s] release_date 解析失败: %s", app_id, e)
                failed += 1
                continue

        if not in_window(release, today):
            logging.info("[%s] 不在 [发布前%d天, 发布日] 窗口内, 跳过 (release=%s)",
                         app_id, WINDOW_DAYS, release)
            skipped += 1
            continue

        reserve, title = fetch_reserve(app_id)
        if reserve is None:
            failed += 1
            continue
        title = title or g.get("name") or app_id
        tracked = upsert_row(DATA_FILE, today, app_id, reserve, title)
        logging.info("[%s] %s reserve=%d (已跟踪 %d 天) -> %s",
                     app_id, title, reserve, tracked, DATA_FILE)
        ok += 1
        time.sleep(SLEEP_BETWEEN)

    logging.info("Done. ok=%d skipped=%d failed=%d", ok, skipped, failed)
    return 0 if failed == 0 else 1


def main() -> None:
    parser = argparse.ArgumentParser(description="TapTap reservation daily crawler")
    parser.add_argument("--once", action="store_true", help="抓取一次后退出 (默认行为)")
    parser.parse_args()
    _setup_logging()
    sys.exit(run_once())


if __name__ == "__main__":
    main()

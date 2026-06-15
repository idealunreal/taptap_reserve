# TapTap 预约量跟踪爬虫

跟踪指定游戏 **发布前 30 天** 的每日预约量走势。

## 文件结构

```
taptap_reserve/
├── crawler.py        # 主程序
├── games.json        # 跟踪列表 (app_id + 发布日期)
├── data/             # 输出: 每个游戏一份 CSV
│   └── {app_id}.csv  # 列: date, reserve_count, title
└── crawler.log
```

## 配置 `games.json`

```json
[
  { "app_id": "228375", "name": "示例游戏", "release_date": "2026-06-15" }
]
```

`app_id` 取自 TapTap 详情页 URL：`https://www.taptap.cn/app/228375` 中的数字。

## 运行

```powershell
pip install requests
python d:\tmp\taptap_reserve\crawler.py
```

只会在 `release_date - 30天 ~ release_date` 区间内写入数据；同一天重复跑会覆盖当日记录（幂等）。

## 每日自动执行 (Windows 任务计划程序)

```powershell
$action  = New-ScheduledTaskAction -Execute "python" -Argument "d:\tmp\taptap_reserve\crawler.py"
$trigger = New-ScheduledTaskTrigger -Daily -At 10:00am
Register-ScheduledTask -TaskName "TapTapReserveCrawler" -Action $action -Trigger $trigger
```

## 备注

- TapTap web API (`/webapiv2/app/v2/detail-by-id/{app_id}`) 是公开未授权接口，字段可能随站点改版变动；若 `reserve_count` 取不到，日志会打印实际返回字段，调整 `fetch_reserve()` 内取值即可。
- 若需要历史回填（比如今天才开始跟踪、想补昨天数据），TapTap 不开放历史预约量，只能从今天往后采集。

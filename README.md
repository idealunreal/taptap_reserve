# TapTap 预约量跟踪爬虫

跟踪指定游戏 **发布前 30 天** 的每日预约量走势。

## 文件结构

```
taptap_reserve/
├── crawler.py        # 主程序
├── games.json        # 跟踪列表 (app_id + 发布日期)
├── reserve.csv       # 输出: 所有游戏汇总 (列: date, app_id, name, reserve_count, tracked_days)
└── crawler.log
```

> `tracked_days` 表示该游戏**已跟踪的天数**（第几天，从 1 开始），方便一眼看出某款游戏累计采集了多少天。

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

## 每日自动执行 (个人 GitHub Actions ⭐ 推荐)

仓库已内置 [.github/workflows/crawler.yml](.github/workflows/crawler.yml)：北京时间 **10:00 主跑 + 14:17 备份**，自动抓取并把数据 `git push` 回仓库（含整轮重试、推送冲突重试）。

> 注意：**企业组织账号**可能禁用 GitHub 托管 runner（报错 `hosted runners are disabled`）。**个人账号不受此限制**，托管 runner 免费可用（公开仓库无限分钟 / 私有仓库 2000 分钟/月，本任务约 120 分钟/月）。

迁移到个人账号只需 4 步：

```powershell
# 1) 先在个人 GitHub 网页端新建一个【空】仓库(不要勾 README/.gitignore,否则 push 冲突)
#    得到地址,例如 https://github.com/<你的用户名>/<仓库名>.git

# 2) 添加个人 remote 并推送(保留原 origin)
git remote add personal https://github.com/<你的用户名>/<仓库名>.git
git push -u personal main
```

3) 仓库 **Settings → Actions → General → Workflow permissions** → 选 **Read and write permissions** → Save（否则每日 `git push` 回写数据会 403）。

4) **Actions 标签页 → "TapTap Reserve Crawler" → Run workflow** 手动触发一次验证，绿勾即说明配置正确，次日起自动运行。

## 每日自动执行 (Windows 任务计划程序)

```powershell
$action  = New-ScheduledTaskAction -Execute "python" -Argument "d:\tmp\taptap_reserve\crawler.py"
$trigger = New-ScheduledTaskTrigger -Daily -At 10:00am
Register-ScheduledTask -TaskName "TapTapReserveCrawler" -Action $action -Trigger $trigger
```

## 备注

- TapTap web API (`/webapiv2/app/v2/detail-by-id/{app_id}`) 是公开未授权接口，字段可能随站点改版变动；若 `reserve_count` 取不到，日志会打印实际返回字段，调整 `fetch_reserve()` 内取值即可。
- 若需要历史回填（比如今天才开始跟踪、想补昨天数据），TapTap 不开放历史预约量，只能从今天往后采集。

#!/usr/bin/env bash
# TapTap 预约爬虫 —— cron 包装脚本
# 由 crontab 每日定时调用,流程:
#   1) 同步远端(避免推送冲突)
#   2) 跑 crawler.py(整轮重试,代码幂等)
#   3) 把更新后的数据提交并推送回仓库
#
# 设计目标:即使某次部分失败,也尽量保证当天数据被记录上。
set -uo pipefail

# 让 crawler.py 里的 datetime.now() 按北京时间计算采集窗口,
# 与 release_date 口径一致(与 cron 实际触发用的系统时区无关)。
export TZ="Asia/Shanghai"

# 仓库根目录 = 本脚本所在目录(scripts/)的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR" || { echo "无法进入仓库目录 $REPO_DIR"; exit 1; }

RUN_LOG="$REPO_DIR/cron_run.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*" | tee -a "$RUN_LOG"; }

# 优先用 venv 里的 python
PY="python3"
if [ -x "$REPO_DIR/.venv/bin/python" ]; then
  PY="$REPO_DIR/.venv/bin/python"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

log "=== 开始本轮爬取 (branch=$BRANCH, python=$PY) ==="

# 1) 先同步远端,减少推送冲突
git pull --rebase --autostash origin "$BRANCH" >>"$RUN_LOG" 2>&1 \
  || log "git pull 失败(忽略,继续)"

# 2) 跑爬虫,整轮重试(crawler.py 幂等:同一天重复跑只覆盖当天记录)
attempt=1
max_attempts=5
until "$PY" crawler.py --once >>"$RUN_LOG" 2>&1; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    log "爬虫重试 ${max_attempts} 次后仍有失败项,提交已抓到的部分数据"
    break
  fi
  log "第 ${attempt} 次执行未全部成功,60s 后重试..."
  attempt=$((attempt + 1))
  sleep 60
done

# 3) 提交并推送
git add reserve.csv data 2>/dev/null || true
if git diff --staged --quiet; then
  log "没有数据变化,跳过提交"
  log "=== 本轮结束 ==="
  exit 0
fi

git commit -m "chore: update reserve data ($(date +'%Y-%m-%d'))" >>"$RUN_LOG" 2>&1

# push 可能因并发提交失败,rebase 远端后重试几次
for i in 1 2 3 4 5; do
  if git push origin "HEAD:$BRANCH" >>"$RUN_LOG" 2>&1; then
    log "推送成功"
    log "=== 本轮结束 ==="
    exit 0
  fi
  log "第 ${i} 次推送失败,rebase 远端后重试..."
  git pull --rebase --autostash origin "$BRANCH" >>"$RUN_LOG" 2>&1 || true
  sleep 5
done

log "多次重试后仍推送失败"
exit 1

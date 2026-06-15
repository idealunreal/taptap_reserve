#!/usr/bin/env bash
# 容器入口:被调度器(如 Azure Container Apps Jobs / k8s CronJob)按 cron 触发,
# 运行一次后退出。流程与原 GitHub Action 一致:
#   git 模式(提供 GIT_REPO_URL + GIT_TOKEN):
#     clone 最新仓库 -> 整轮重试爬取 -> 提交 -> 推送回仓库
#   本地模式(未提供凭据):
#     直接在 /app 跑一次,写到 /app/reserve.csv(适合 docker run 冒烟测试)
#
# 环境变量:
#   GIT_REPO_URL    形如 https://github.com/<owner>/<repo>.git(git 模式必填)
#   GIT_TOKEN       具有 contents 写权限的 PAT(git 模式必填,作为机密注入)
#   GIT_USER_NAME   提交者名(可选,默认 taptap-crawler-bot)
#   GIT_USER_EMAIL  提交者邮箱(可选)
#   TZ              采集窗口时区(默认镜像内置 Asia/Shanghai)
set -uo pipefail

export TZ="${TZ:-Asia/Shanghai}"
GIT_USER_NAME="${GIT_USER_NAME:-taptap-crawler-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-taptap-crawler-bot@users.noreply.github.com}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }

GIT_MODE=0
WORKDIR=/app

if [ -n "${GIT_REPO_URL:-}" ] && [ -n "${GIT_TOKEN:-}" ]; then
  GIT_MODE=1
  # 把 token 注入 HTTPS URL;clone 后立刻把存储的 remote 改回不含 token 的地址,
  # push/pull 时再显式用带 token 的 URL,避免 token 落在 .git/config 里。
  AUTH_URL="https://x-access-token:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
  WORKDIR=/tmp/taptap-repo

  log "git 模式:clone 最新仓库到 $WORKDIR"
  rm -rf "$WORKDIR"
  if ! git clone --depth 1 "$AUTH_URL" "$WORKDIR"; then
    log "clone 失败,退出"
    exit 1
  fi
  cd "$WORKDIR" || exit 1
  git remote set-url origin "$GIT_REPO_URL"   # 抹掉 config 里的 token
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
else
  log "本地模式:未提供 GIT_REPO_URL/GIT_TOKEN,仅运行一次写入 $WORKDIR"
  cd "$WORKDIR" || exit 1
fi

# 整轮重试:crawler.py 幂等(同一天重复跑只覆盖当天记录),尽量抓全
attempt=1
max_attempts=5
until python crawler.py --once; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    log "爬虫重试 ${max_attempts} 次后仍有失败项,提交已抓到的部分数据"
    break
  fi
  log "第 ${attempt} 次执行未全部成功,60s 后重试..."
  attempt=$((attempt + 1))
  sleep 60
done

if [ "$GIT_MODE" -eq 0 ]; then
  log "本地模式结束"
  exit 0
fi

# 提交并推送
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
git add reserve.csv data 2>/dev/null || true
if git diff --staged --quiet; then
  log "没有数据变化,跳过提交"
  exit 0
fi

git commit -m "chore: update reserve data ($(date +'%Y-%m-%d'))"

for i in 1 2 3 4 5; do
  if git push "$AUTH_URL" "HEAD:$BRANCH"; then
    log "推送成功"
    exit 0
  fi
  log "第 ${i} 次推送失败,rebase 远端后重试..."
  git pull --rebase --autostash "$AUTH_URL" "$BRANCH" || true
  sleep 5
done

log "多次重试后仍推送失败"
exit 1

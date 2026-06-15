#!/usr/bin/env bash
# 一次性初始化脚本(在云 VM 上 clone 仓库后跑一次):
#   1) 创建 Python 虚拟环境并安装依赖
#   2) 给运行脚本加可执行权限
#   3) 安装 crontab 定时任务(北京时间 10:00 主跑 + 14:00 备份)
#
# 用法:
#   cd <仓库目录>
#   bash scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

echo "==> 仓库目录: $REPO_DIR"

# 1) venv + 依赖
if ! python3 -m venv .venv 2>/dev/null; then
  echo "创建 venv 失败。请先安装:  sudo apt-get install -y python3-venv  (Debian/Ubuntu)"
  echo "或:  sudo yum install -y python3  (RHEL/Oracle Linux)"
  exit 1
fi
.venv/bin/pip install --upgrade pip >/dev/null
.venv/bin/pip install -r requirements.txt
echo "==> 依赖安装完成"

# 2) 可执行权限 + 自动提交所需的 git 身份(仓库级,不影响全局配置)
chmod +x "$SCRIPT_DIR/run_crawler.sh"
git config user.name  "taptap-crawler-bot"
git config user.email "taptap-crawler-bot@users.noreply.github.com"

# 3) 安装 crontab
#    使用 CRON_TZ=Asia/Shanghai,这样无论 VM 系统时区是 UTC 还是别的,
#    下面的 10:00 / 14:00 都按北京时间触发(Ubuntu/Debian/cronie 均支持)。
#    14:00 那条是备份兜底:主跑成功且数据没变时会自动跳过提交。
CRON_TMP="$(mktemp)"
# 保留其他已有任务,先剔除本任务的旧行(幂等,可重复执行)
crontab -l 2>/dev/null \
  | grep -v 'run_crawler.sh' \
  | grep -v 'CRON_TZ=Asia/Shanghai # taptap' \
  > "$CRON_TMP" || true
cat >> "$CRON_TMP" <<EOF
CRON_TZ=Asia/Shanghai # taptap
0 10 * * * $SCRIPT_DIR/run_crawler.sh # taptap-main
0 14 * * * $SCRIPT_DIR/run_crawler.sh # taptap-backup
EOF
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

echo "==> 已安装 crontab:"
crontab -l | grep -E 'taptap|run_crawler' || true

echo ""
echo "完成。可手动测试一次:  $SCRIPT_DIR/run_crawler.sh"
echo "查看运行日志:          tail -f $REPO_DIR/cron_run.log"

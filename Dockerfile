FROM python:3.12-slim

# git: clone/commit/push 数据回仓库; tzdata: 让 TZ=Asia/Shanghai 生效;
# ca-certificates: HTTPS 访问 TapTap API 与 GitHub。
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 先装依赖,利用 Docker 层缓存(requirements 不变时不重装)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 再拷代码与入口脚本
COPY crawler.py .
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 以非 root 运行;并让 /app 可写,便于无 git 凭据时的本地冒烟测试
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

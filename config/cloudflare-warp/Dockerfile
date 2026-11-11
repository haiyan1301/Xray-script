FROM ubuntu:jammy

# 可选固定 cloudflare-warp 包版本（留空则安装仓库最新版本；构建参数便于复现问题版本）。
ARG WARP_VERSION=

# 用 bash 执行 RUN，保证管道失败（curl | gpg）能被 pipefail 捕获。
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 安装运行期依赖（socat 用于 40001 -> 40000 转发），导入官方 apt 源并安装 cloudflare-warp。
# 只清理 apt 索引/缓存/日志，保留 /var/lib/dpkg 以便排障时核对已装版本。
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        socat ca-certificates curl gnupg && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ jammy main" \
        > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    if [[ -n "${WARP_VERSION}" ]]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "cloudflare-warp=${WARP_VERSION}"; \
    else \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloudflare-warp; \
    fi && \
    apt-get autoremove --yes && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/*

COPY startup.sh /bin/startup.sh
COPY healthcheck.sh /bin/healthcheck.sh
RUN chmod a+x /bin/startup.sh /bin/healthcheck.sh

# 健康检查：ready 标记 + warp-cli status Connected + 40000 可连接（见 healthcheck.sh）。
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 CMD /bin/healthcheck.sh

ENTRYPOINT ["/bin/startup.sh"]

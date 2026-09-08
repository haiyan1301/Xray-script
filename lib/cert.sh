#!/usr/bin/env bash
# =============================================================================
# 脚本名称: cert.sh
# 功能描述: 证书与 ACME 客户端的共享原语（只定义函数）。
#           1) 证书对校验：公钥匹配 + 未过期；
#           2) 部署权限：证书目录 750 / 证书文件 640 + 属主与 xray-nginx 组；
#           3) 成对备份与成对回滚（缺哪个就记哪个，回滚时缺的删掉）；
#           4) acme.sh 客户端安装的三步（下载 / 自动升级 / 默认 CA）；
#           5) 签发失败后带 --debug 重试一次。
#
# 为什么单独成库：core/handler.sh 与 service/ssl.sh 是两个进程（后者不能 source
# lib/common.sh，见门禁 S6），此前各自实现了一份「备份 / 安装 / 权限 / 恢复」。
# 本文件只定义函数，不定义颜色、PATH 等常量，两边都能安全 source。
#
# 约定:
#   - 打印文案由调用方负责（各进程有自己的 i18n 命名空间），本文件只返回状态；
#   - 需要回传两个值时用 stdout（cert_backup_pair），不引入全局变量。
#
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# 防止重复 source
[[ -n "${_CERT_SH_LOADED:-}" ]] && return 0
readonly _CERT_SH_LOADED=1

# =============================================================================
# 函数名称: cert_validate_pair
# 功能描述: 校验 fullchain / privkey 是否为可用的证书对。
#           证书与私钥都必须可读、公钥一致，且证书尚未过期。
# 参数:
#   $1: fullchain 路径
#   $2: privkey 路径
# 返回值: 0-是可用的一对 1-不可读 / 不匹配 / 已过期
# =============================================================================
function cert_validate_pair() {
    local fullchain="$1"
    local privkey="$2"
    local cert_public_key key_public_key

    [[ -r "${fullchain}" && -r "${privkey}" ]] || return 1
    cert_public_key="$(openssl x509 -in "${fullchain}" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform PEM 2>/dev/null)" || return 1
    key_public_key="$(openssl pkey -in "${privkey}" -pubout -outform PEM 2>/dev/null)" || return 1
    [[ -n "${cert_public_key}" && "${cert_public_key}" == "${key_public_key}" ]] ||
        return 1
    openssl x509 -in "${fullchain}" -noout -checkend 0 >/dev/null 2>&1
}

# =============================================================================
# 函数名称: cert_set_permissions
# 功能描述: 设置证书目录与两个证书文件的属主 / 权限，供 Nginx 或 Xray 的
#           worker 用户读取。存在 xray-nginx 组时用它做属组，否则退回用户同名组。
# 参数:
#   $1: 证书目录
#   $2: 属主用户（xray / nginx）
# 返回值:
#   0-全部设置成功（或主机上既无 xray-nginx 组也无该用户，跳过 chown）
#   1-属主参数不合法，或 chmod 失败（两侧调用方都视为硬失败）
#   2-尝试过 chown 但失败（属主未下发）。两侧策略不同：core/handler.sh 沿用
#     迁移前的「chown 失败即回滚」，service/ssl.sh 只告警——证书已经签发并安装，
#     属主没下发不影响 root 主进程读取证书，为此回滚新证书比迁移前更糟。
# =============================================================================
function cert_set_permissions() {
    local cert_dir="$1"
    local owner="$2"
    local chown_status=0

    case "${owner}" in
    xray | nginx) ;;
    *) return 1 ;;
    esac

    if getent group xray-nginx >/dev/null 2>&1; then
        chown "${owner}:xray-nginx" \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || chown_status=1
    elif id -u "${owner}" >/dev/null 2>&1; then
        chown "${owner}:${owner}" \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || chown_status=1
    fi
    chmod 750 "${cert_dir}" 2>/dev/null || return 1
    chmod 640 "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" 2>/dev/null || return 1
    [[ "${chown_status}" -eq 0 ]] || return 2
}

# =============================================================================
# 函数名称: cert_backup_pair
# 功能描述: 把证书目录里的 fullchain / privkey 成对备份到备份目录。
#           不存在的文件不备份，回滚时按「原来没有」处理。
#           只接受常规文件：符号链接一律拒绝（跟随后复制会让回滚把链接指向的
#           内容覆盖回去，与调用方「证书文件不是链接」的前提冲突）。
# 参数:
#   $1: 证书目录
#   $2: 备份目录（必须已存在）
# 输出: "<had_fullchain> <had_privkey>"（0/1，空格分隔）
# 返回值: 0-成功 1-备份目录不存在 / 存在非普通文件 / 复制失败
# =============================================================================
function cert_backup_pair() {
    local cert_dir="$1"
    local backup_dir="$2"
    local had_fullchain=0
    local had_privkey=0

    [[ -d "${backup_dir}" ]] || return 1
    if [[ -e "${cert_dir}/fullchain.pem" ]]; then
        [[ -f "${cert_dir}/fullchain.pem" && ! -L "${cert_dir}/fullchain.pem" ]] ||
            return 1
        cp -p -- "${cert_dir}/fullchain.pem" "${backup_dir}/fullchain.pem" || return 1
        had_fullchain=1
    fi
    if [[ -e "${cert_dir}/privkey.pem" ]]; then
        [[ -f "${cert_dir}/privkey.pem" && ! -L "${cert_dir}/privkey.pem" ]] ||
            return 1
        cp -p -- "${cert_dir}/privkey.pem" "${backup_dir}/privkey.pem" || return 1
        had_privkey=1
    fi
    printf '%s %s\n' "${had_fullchain}" "${had_privkey}"
}

# =============================================================================
# 函数名称: cert_restore_pair
# 功能描述: 按 cert_backup_pair 记录的标志回滚证书对：
#           备份过的复制回去，原来没有的删除，避免留下不匹配的一对。
# 参数:
#   $1: 证书目录
#   $2: 备份目录
#   $3: had_fullchain（0/1）
#   $4: had_privkey（0/1）
# 返回值: 0-全部回滚成功 1-任一步失败
# =============================================================================
function cert_restore_pair() {
    local cert_dir="$1"
    local backup_dir="$2"
    local had_fullchain="$3"
    local had_privkey="$4"
    local restore_status=0

    if [[ "${had_fullchain}" -eq 1 ]]; then
        cp -p -- "${backup_dir}/fullchain.pem" "${cert_dir}/fullchain.pem" ||
            restore_status=1
    else
        rm -f -- "${cert_dir}/fullchain.pem" || restore_status=1
    fi
    if [[ "${had_privkey}" -eq 1 ]]; then
        cp -p -- "${backup_dir}/privkey.pem" "${cert_dir}/privkey.pem" ||
            restore_status=1
    else
        rm -f -- "${cert_dir}/privkey.pem" || restore_status=1
    fi
    return "${restore_status}"
}

# =============================================================================
# ACME 客户端安装：三个步骤各自返回状态，调用方按自己的 i18n 命名空间打印文案。
# 安装路径固定为 ${HOME}/.acme.sh（与 acme.sh 官方安装脚本一致）。
# =============================================================================

# 参数: $1-账户邮箱
function acme_client_download() {
    curl https://get.acme.sh | sh -s email="$1"
}

function acme_client_enable_autoupgrade() {
    "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade
}

function acme_client_set_default_ca() {
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server zerossl
}

# =============================================================================
# 函数名称: run_with_debug_retry
# 功能描述: 执行命令，失败时按约定追加 --debug 重试一次。
#           90/91 是「Nginx 停止/恢复失败」的约定状态码：这种失败重试也不会改变
#           结果，所以直接原样返回。注意这是防御性分支——当前四处调用点传入的
#           都是 acme.sh 的退出码，而外层 run_with_nginx_temporarily_stopped 会把
#           内层任何非 0 折叠成 1，因此现网不会产生 90/91；若将来把本函数提到外层
#           （直接包住 run_with_nginx_temporarily_stopped），该分支才会生效。
# 参数:
#   $1: 重试前调用的提示函数名（空字符串表示不打印）
#   $@: 命令及其参数
# 返回值: 命令的退出码（两次都失败时为第二次的退出码）
# =============================================================================
function run_with_debug_retry() {
    local notify="${1:-}"
    local status=0

    shift
    "$@" && return 0
    status=$?
    ((status == 90 || status == 91)) && return "${status}"
    [[ -z "${notify}" ]] || "${notify}"
    "$@" --debug
}

#!/usr/bin/env bash
#
# Copyright (C) 2025 zxcvos
#
# Xray-script:
#   https://github.com/zxcvos/Xray-script
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: read.sh
# 功能描述: 根据传入的参数，从国际化 (i18n) 配置文件中读取对应的提示信息，
#           并从标准输入读取用户输入，返回用户输入的内容。
#           主要用于交互式配置脚本，提供多语言支持。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, cut, sed
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 定义颜色代码，用于在终端输出带颜色的信息
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly RED='\033[31m'    # 红色
readonly NC='\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly CONFIG_DIR="${PROJECT_ROOT}/config"                   # 配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主要配置文件路径

# 复用统一的子库（i18n 取值 / 日志 / 字段表）。它们只定义函数与数据表，不定义
# 颜色、PATH 等常量，因此不与本脚本自己的 readonly 定义冲突。
source "${PROJECT_ROOT}/lib/i18n.sh"
source "${PROJECT_ROOT}/lib/log.sh"
# 字段身份（提示样式 / i18n 键 / 额外提示）的单一来源，见 lib/protocols.sh。
source "${PROJECT_ROOT}/lib/protocols.sh"


# =============================================================================
# 函数名称: read_input
# 功能描述: 根据类型和消息内容，在终端打印格式化的提示信息。
# 参数:
#   $1: 类型 (type) - "config" 或 "rule"，决定提示信息的颜色和标题前缀
#   $2: 消息内容 (msg) - 具体的提示文本
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function read_input() {
    local type="$1"      # 获取类型参数
    local color="$GREEN" # 默认颜色为绿色
    # 从 i18n 数据中读取 "配置" 的标题
    local title="$(t '.title.config')"

    # 如果类型是 "rule"
    if [[ "$type" == "rule" ]]; then
        color="$YELLOW" # 设置颜色为黄色
        # 从 i18n 数据中读取 "路由规则" 的标题
        title="$(t '.title.route')"
    fi

    local msg="$2" # 获取消息内容参数

    # 如果类型是 "rule"，在消息后追加 "(可设置多个值)" 的提示
    if [[ "$type" == "rule" ]]; then
        msg="$msg ($(t '.title.multiple_values'))"
    fi

    # 使用指定颜色和标题打印提示信息到标准错误输出
    printf "${color}[${title}]${NC} ${msg} " >&2
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 检查传入的第一个参数是否是 lib/protocols.sh 里登记的字段。
#           3. 从字段表取提示样式、i18n 键与额外提示。
#           4. 调用 read_input 显示提示，从标准输入读取用户输入并输出。
#           提示样式、i18n 键与额外提示都来自 lib/protocols.sh 的字段表，
#           本脚本不再维护第二份选项清单（否则两边会悄悄漂移）。
# 参数:
#   $1: 命令行选项 (例如 --port, --uuid)
#   $@: 剩余参数 (此脚本中未使用)
# 返回值: 用户输入的内容 (stdout 输出)；未知选项不输出任何内容；
#         stdin 已关闭 / EOF 时返回 1 且不输出（与「用户输入空行」区分）
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local opt="${1#--}"
    # 未登记的选项保持静默返回：调用方会拿到空输入而不是报错。
    field_known "${opt}" || return 0

    # 额外提示（例如 --short / --xhttp-mode 的格式说明）在提示行之前打印
    local tip=""
    tip="$(field_tip_key "${opt}")"
    [[ -z "${tip}" ]] || log_tip "$(t ".${CUR_FILE}.${tip}")" >&2

    # 调用 read_input 函数显示提示信息
    read_input "$(field_type "${opt}")" "$(t ".${CUR_FILE}.$(field_i18n_key "${opt}")")"

    # 从标准输入读取一行用户输入。IFS= 保留首尾空白；read 失败（EOF / stdin 关闭）
    # 必须区分于「用户按了回车」：返回非 0，让调用方决定中止，而不是当作空输入。
    local input
    if ! IFS= read -r input; then
        return 1
    fi

    # 用 printf 而非 echo：输入为 -n / -e 等时 echo 会把它当选项而不输出内容。
    printf '%s\n' "${input}"
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"

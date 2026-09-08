#!/usr/bin/env bash
# =============================================================================
# 脚本名称: i18n.sh
# 功能描述: 国际化取值层。
#           在 load_i18n 时把 i18n/<lang>.json 一次性展开进关联数组 I18N，
#           之后用 t <键> 取值，不再每个调用点 fork 一次 jq 重新解析整份 JSON。
#           本文件刻意不依赖 lib/common.sh：service/*.sh 是独立子进程脚本，
#           有自己的颜色常量与运行环境，但也需要同一份取值实现。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash 4+（关联数组）、jq
# =============================================================================

# 防止重复 source
[[ -n "${_I18N_SH_LOADED:-}" ]] && return 0
readonly _I18N_SH_LOADED=1

# --- 国际化文本表 ---
# 键为 JSON 路径的点号形式（不含前导点），例如 handler.title.info。
declare -A I18N=()

# =============================================================================
# 函数名称: t
# 功能描述: 取一条 i18n 文本；传多个键时取第一个非空值（等价于 jq 的 // 回退）。
# 参数:
#   $@: 键。允许带前导点（如 ".handler.xxx"），便于调用点沿用旧的 jq 表达式。
# 返回值: 0；文本写到标准输出。键都不存在时输出空串。
# =============================================================================
function t() {
    local key text
    for key in "$@"; do
        text="${I18N["${key#.}"]:-}"
        if [[ -n "${text}" ]]; then
            printf '%s' "${text}"
            return 0
        fi
    done
    return 0
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
#           从 config.json 读取语言设置，加载对应的 JSON i18n 文件到 I18N。
# 参数: 无（使用调用方已定义的全局变量 SCRIPT_CONFIG_PATH 和 I18N_DIR）
# 返回值: 无 (直接修改全局变量 I18N)。语言文件缺失时打印错误并 exit 1。
# =============================================================================
function load_i18n() {
    local lang=''
    lang="$(jq -r '.language // ""' "${SCRIPT_CONFIG_PATH:-}" 2>/dev/null)" || lang=''
    if [[ "${lang}" == 'auto' ]]; then
        lang="${LANG:-}"
        lang="${lang%%.*}"
        lang="${lang%%_*}"
        [[ "${lang,,}" == 'zh' ]] && lang='zh' || lang='en'
    fi
    # 如果语言为空或为 "null"，则默认使用中文
    if [[ -z "${lang}" || "${lang}" == 'null' ]]; then
        lang='zh'
    fi
    local i18n_file="${I18N_DIR}/${lang}.json"
    if [[ ! -f "${i18n_file}" ]]; then
        if [[ "${lang}" == 'zh' ]]; then
            printf '%s[错误]%s 文件不存在: %s\n' "${RED:-}" "${NC:-}" "${i18n_file}" >&2
        else
            printf '%s[Error]%s File Not Found: %s\n' "${RED:-}" "${NC:-}" "${i18n_file}" >&2
        fi
        exit 1
    fi
    # 一次性把全部叶子节点读进关联数组：每个键一次 fork 是旧实现的 752 次。
    # 值中若含制表符/换行/反斜杠会被 @tsv 转义，i18n 文件已校验不含这些字符。
    I18N=()
    local key value
    while IFS=$'\t' read -r key value; do
        [[ -n "${key}" ]] || continue
        I18N["${key}"]="${value}"
    done < <(jq -r 'paths(scalars) as $p | [($p | join(".")), (getpath($p) | tostring)] | @tsv' \
        "${i18n_file}")
}

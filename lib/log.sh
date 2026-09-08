#!/usr/bin/env bash
# =============================================================================
# 文件名称: log.sh
# 功能描述: 统一日志层——全部提示消息的唯一实现。
#           只定义日志函数，不定义颜色常量：core/*.sh 经 lib/common.sh 拿到
#           颜色，service/*.sh 各自 readonly 定义了颜色，本文件用 ${COLOR:-}
#           取值，因此两种场景都能安全 source。
#
# 流约定: 全部写 stderr（与各脚本原有实现一致，避免改变既有重定向行为）。
#         需要「打印后退出」的入口保留历史语义，见文件末尾的兼容层。
# 依赖: lib/i18n.sh 的 t()（在调用时解析，source 时不要求已加载）
# =============================================================================

[[ -n "${_LOG_SH_LOADED:-}" ]] && return 0
readonly _LOG_SH_LOADED=1

# =============================================================================
# 函数名称: log_info / log_warn / log_error / log_pass / log_fail / log_test
#            log_tip / log_config
# 功能描述: 按级别打印带颜色标题的提示消息（均写 stderr）。
#           标题取自 i18n 的 .title.*，颜色沿用全仓既有约定：
#           信息/配置=绿、提示/警告/测试=黄、错误/失败=红、通过=绿。
# 参数:
#   $@: 消息内容
# 返回值: 0
# =============================================================================
# 注意: 颜色常量是字面量 '\033[32m'，只有写在 printf 的**格式串**里才会被转义；
# 放进参数位置会原样打印，故这里保留「颜色拼进格式串」的写法。
function log_info() { printf "${GREEN:-}[%s]${NC:-} %s\n" "$(t '.title.info')" "$*" >&2; }
function log_warn() { printf "${YELLOW:-}[%s]${NC:-} %s\n" "$(t '.title.warn')" "$*" >&2; }
function log_error() { printf "${RED:-}[%s]${NC:-} %s\n" "$(t '.title.error')" "$*" >&2; }
function log_pass() { printf "${GREEN:-}[%s]${NC:-} %s\n" "$(t '.title.pass')" "$*" >&2; }
function log_fail() { printf "${RED:-}[%s]${NC:-} %s\n" "$(t '.title.fail')" "$*" >&2; }
function log_test() { printf "${YELLOW:-}[%s]${NC:-} %s\n" "$(t '.title.test')" "$*" >&2; }
function log_tip() { printf "${YELLOW:-}[%s]${NC:-} %s\n" "$(t '.title.tip')" "$*" >&2; }
function log_config() { printf "${GREEN:-}[%s]${NC:-} %s\n" "$(t '.title.config')" "$*" >&2; }

# =============================================================================
# 兼容层: 历史函数名 -> 统一实现，调用点无需改动。
#   print_info/print_warn/print_error  service/{ssl,nginx,docker}.sh
#   _info/_pass/_fail/_test            core/check.sh
#   _error                             core/handler.sh（打印后 exit 1）
# 注意: print_error 与 _error 沿用「打印后退出 1」的历史语义。
# =============================================================================
function print_info() { log_info "$*"; }
function print_warn() { log_warn "$*"; }
function print_error() {
    log_error "$*"
    exit 1
}
function _info() { log_info "$1"; }
function _pass() { log_pass "$1"; }
function _fail() { log_fail "$1"; }
function _test() { log_test "$1"; }
function _error() {
    log_error "$*"
    exit 1
}

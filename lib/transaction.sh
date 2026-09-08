#!/usr/bin/env bash
# =============================================================================
# 脚本名称: transaction.sh
# 功能描述: 事务调度骨架的共享实现（只定义函数）。
#           1) 在子 shell 内注册 EXIT / HUP / INT / TERM 四个 trap；
#           2) 统一信号退出码（HUP=129 / INT=130 / TERM=143）；
#           3) 提交 / 已变更 / 已回滚 三个标记与查询；
#           4) 退出处理函数的第一句统一注销 trap（可选在清理期间屏蔽信号）。
#
# 为什么只收敛「调度骨架」：core/main.sh 的 install_protocol、service/ssl.sh 的
# issue_certificate、service/nginx.sh 的 install_nginx_update_transaction 三套实现
# 共享的只有这一层——子 shell + 四 trap + 注销首句 + 三标记 + 显式 return 1。
# 它们的快照集合、回滚体、提交条件、锁策略、清理策略各不相同（逐项比对见
# code_optimization_plan.md 的 RF3 落地记录），强行统一会改变可观察行为，
# 因此回滚体仍留在调用方，本库只提供调度原语。
#
# 约定:
#   - 状态放在 TXN_ 前缀的变量里，由 txn_begin 在**调用方所在子 shell**中初始化，
#     因此天然是每次事务私有的；不要在事务外读写它们；
#   - txn_begin 注册的 EXIT trap 只负责调用调用方的 finish 函数并把退出码传进去，
#     finish 函数必须自己 exit（三套现状都是如此）；
#   - 本文件只定义函数，不定义颜色、PATH 等常量，独立进程可安全 source。
#
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# 防止重复 source
[[ -n "${_TRANSACTION_SH_LOADED:-}" ]] && return 0
readonly _TRANSACTION_SH_LOADED=1

# =============================================================================
# 函数名称: txn_begin
# 功能描述: 初始化事务状态并注册退出 / 信号处理。
#           必须在事务函数的子 shell 内、任何变更动作之前调用。
# 参数:
#   $1: 退出处理函数名（收到唯一参数：子 shell 的退出码）
# 返回值: 0
# =============================================================================
function txn_begin() {
    TXN_FINISH_FUNCTION="$1"
    TXN_COMMITTED=0
    TXN_MUTATION_STARTED=0
    TXN_ROLLBACK_ATTEMPTED=0

    trap 'txn_exit_handler' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# =============================================================================
# 函数名称: txn_exit_handler
# 功能描述: EXIT trap 的固定入口：把退出码原样交给调用方的 finish 函数。
#           finish 函数负责注销 trap、执行回滚 / 清理并 exit。
# 参数: 无（退出码取自 trap 触发时的 $?）
# 返回值: 无（finish 函数会 exit）
# =============================================================================
function txn_exit_handler() {
    local status=$?

    "${TXN_FINISH_FUNCTION}" "${status}"
}

# =============================================================================
# 函数名称: txn_finish_enter
# 功能描述: 退出处理函数的第一句：注销 trap，防止清理过程中的动作再次触发
#           EXIT 造成递归。
# 参数:
#   $1: 'ignore' 表示清理期间屏蔽 HUP/INT/TERM（ssl.sh 的现状）；缺省恢复默认
# =============================================================================
function txn_finish_enter() {
    if [[ "${1:-}" == 'ignore' ]]; then
        trap - EXIT
        trap '' HUP INT TERM
    else
        trap - EXIT HUP INT TERM
    fi
}

# =============================================================================
# 标记与查询
# =============================================================================

# 标记事务已提交（提交之后的失败不再回滚）
function txn_commit() { TXN_COMMITTED=1; }

# 标记「已经动过现场」，退出时需要考虑回滚
function txn_mark_mutation() { TXN_MUTATION_STARTED=1; }

function txn_is_committed() { [[ "${TXN_COMMITTED}" -eq 1 ]]; }

function txn_is_mutation_started() { [[ "${TXN_MUTATION_STARTED}" -eq 1 ]]; }

# 是否需要回滚：未提交且已动过现场。提交条件本身由调用方判定（三套各不相同）。
function txn_should_rollback() {
    [[ "${TXN_COMMITTED}" -eq 0 && "${TXN_MUTATION_STARTED}" -eq 1 ]]
}

# 第一次调用返回 0 并把回滚标记置位，之后返回 1。
# 用于「回滚只能跑一次」的守卫；也可直接调用以无条件置位（忽略返回值）。
function txn_begin_rollback() {
    [[ "${TXN_ROLLBACK_ATTEMPTED}" -eq 0 ]] || return 1
    TXN_ROLLBACK_ATTEMPTED=1
}

function txn_rollback_attempted() { [[ "${TXN_ROLLBACK_ATTEMPTED}" -eq 1 ]]; }

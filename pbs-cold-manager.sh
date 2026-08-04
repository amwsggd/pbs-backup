#!/bin/bash
set -euo pipefail

# pbs-cold-manager.sh — 多目标备份/恢复管理包装器
#
# 配合 pbs-cold-manager.conf 使用:
#   backup [目标...]   按配置顺序逐目标调用其配置的备份脚本(默认全部目标;
#                      指定目标时按参数顺序)。单个目标失败不阻断后续目标,
#                      结束时汇总,任一失败则整体退出码 1。
#   restore <目标>     调用该目标配置的恢复脚本恢复(必须指定一个目标)。
#   list               列出各目标解析后的脚本与关键配置。
#
# 每个目标可配置:BACKUP_SCRIPT/RESTORE_SCRIPT(未配则用 DEFAULT_* 脚本,
# 避免重复配置),以及透传变量列表中任意变量的目标级覆盖(<目标>_<变量>)。

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="${PBS_COLD_CONF:-$SCRIPT_DIR/pbs-cold-manager.conf}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

usage() {
    cat >&2 <<EOF
用法: $0 backup [目标...] | restore <目标> | list
配置文件: $CONF (PBS_COLD_CONF 可覆盖)
EOF
    exit 1
}

[ -r "$CONF" ] || { log "ERROR: 配置文件不可读: $CONF"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

# 可透传给底层脚本的变量(两套脚本配置项的并集;目标级 <目标>_<变量> 优先)
PASSTHRU_VARS=(
    ZVOL S3_BUCKET S3_PREFIX S3_ENDPOINT PASSPHRASE_FILE WEAK_PASS
    VOL_SIZE_MB CLIPS_PER_VOL CLIP_MIN_MB CLIP_MAX_MB ENTRY_DIR VOL_BASE
    TMP_DIR RESTORE_TMP DEST_ZVOL DEST_SIZE PART_SIZE PART_FORMAT SNAP_TAG
    SEVENZ HEADER_SEED PAD_SLACK KEEP_SNAPSHOTS FULL_EVERY KEEP_CHAINS
    RETRY_ATTEMPTS RETRY_DELAY
)

TARGETS=(${TARGETS[@]+"${TARGETS[@]}"})
DEFAULT_BACKUP_SCRIPT="${DEFAULT_BACKUP_SCRIPT:-pbs-cold-backup-7z.sh}"
DEFAULT_RESTORE_SCRIPT="${DEFAULT_RESTORE_SCRIPT:-pbs-cold-restore-7z.sh}"

# 相对路径的脚本相对包装器所在目录解析
resolve_script() {
    case "$1" in
        /*) echo "$1" ;;
        *)  echo "$SCRIPT_DIR/$1" ;;
    esac
}

is_known_target() {
    local t
    for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
        [ "$t" = "$1" ] && return 0
    done
    return 1
}

check_target() {
    case "$1" in
        *[!A-Za-z0-9_]*|"")
            log "ERROR: 非法目标名: '$1'"; exit 1 ;;
    esac
    if ! is_known_target "$1"; then
        log "ERROR: 未知目标: '$1'(配置中 TARGETS=(${TARGETS[*]:-}))"
        exit 1
    fi
}

# 取目标级变量,未设置回退共享层: effective_var <目标> <变量名>
effective_var() {
    local tv="${1}_${2}"
    if [ -n "${!tv:-}" ]; then
        echo "${!tv}"
    else
        echo "${!2:-}"
    fi
}

# 组装环境并调用目标脚本: run_target <目标> backup|restore
run_target() {
    local t="$1" mode="$2"
    local sv script
    if [ "$mode" = backup ]; then
        sv="${t}_BACKUP_SCRIPT"
        script=$(resolve_script "${!sv:-$DEFAULT_BACKUP_SCRIPT}")
    else
        sv="${t}_RESTORE_SCRIPT"
        script=$(resolve_script "${!sv:-$DEFAULT_RESTORE_SCRIPT}")
    fi
    [ -r "$script" ] || { log "ERROR: [$t] 脚本不可读: $script"; return 1; }

    local -a env_args=()
    local var val
    for var in "${PASSTHRU_VARS[@]}"; do
        val=$(effective_var "$t" "$var")
        [ -n "$val" ] && env_args+=("$var=$val")
    done
    log "[$t] $mode → $(basename "$script") (S3: $(effective_var "$t" S3_BUCKET)/$(effective_var "$t" S3_PREFIX))"
    env "${env_args[@]}" bash "$script"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
    backup)
        targets=()
        if [ $# -gt 0 ]; then
            targets=("$@")
        else
            targets=(${TARGETS[@]+"${TARGETS[@]}"})
        fi
        [ ${#targets[@]} -gt 0 ] || { log "ERROR: 配置中没有任何目标"; exit 1; }
        for t in "${targets[@]}"; do check_target "$t"; done

        failed=()
        for t in "${targets[@]}"; do
            log "===== backup target: $t ====="
            if ! run_target "$t" backup; then
                log "ERROR: [$t] backup failed, continuing with next target"
                failed+=("$t")
            fi
        done
        if [ ${#failed[@]} -gt 0 ]; then
            log "ERROR: backup finished with ${#failed[@]} failed target(s): ${failed[*]}"
            exit 1
        fi
        log "Backup done: ${#targets[@]} target(s) all succeeded"
        ;;
    restore)
        [ $# -eq 1 ] || usage
        check_target "$1"
        log "===== restore target: $1 ====="
        run_target "$1" restore
        ;;
    list)
        for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
            bv="${t}_BACKUP_SCRIPT"; rv="${t}_RESTORE_SCRIPT"
            bshow="${!bv:-$DEFAULT_BACKUP_SCRIPT}"; [ -z "${!bv:-}" ] && bshow="$bshow (默认)"
            rshow="${!rv:-$DEFAULT_RESTORE_SCRIPT}"; [ -z "${!rv:-}" ] && rshow="$rshow (默认)"
            printf '%s\n  backup : %s\n  restore: %s\n  s3     : %s/%s @ %s\n' \
                "$t" "$bshow" "$rshow" \
                "$(effective_var "$t" S3_BUCKET)" \
                "$(effective_var "$t" S3_PREFIX)" \
                "$(effective_var "$t" S3_ENDPOINT)"
        done
        ;;
    *)
        usage
        ;;
esac

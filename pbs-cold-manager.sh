#!/bin/bash
set -euo pipefail

# pbs-cold-manager.sh — 多源×多目标 备份/恢复管理包装器
#
# 配合 pbs-cold-manager.conf 使用(bash 语法,被 source):
#   backup [目标...]   逐 (源,目标) 调用该目标配置的备份脚本(7z 或旧裸流)。
#                      同一源的各目标注入同一 BACKUP_TS → 同名快照
#                      (源@pbs-<ts>,与旧版一致)被复用,不重复创建。
#                      单目标失败不阻断,结束汇总,任一失败整体退出码 1。
#                      指定目标时只跑这些目标(每个源按其目标交集)。
#   restore <目标> [源] 调用该目标配置的恢复脚本。目标配置了多个源时
#                      必须指定源;只有一个源时可省略。
#   list               列出各目标解析后的脚本/密钥/源/S3 配置。
#
# 全量/增量与增量基由脚本按 S3 链推导(链目录名/inc-<ts> 即快照 ts);
# 上传失败由脚本删除本次创建的快照与本次 S3 内容(EXIT trap 兜底,
# 快照优先保证删除),既有数据不动,日志记录清楚。
#
# 密钥管理:conf 里 KEYS 注册表定义 密钥id → 密钥文件路径;每个 (源,目标)
#   关系按 <目标>_<源slug>_KEY → <目标>_KEY → 共享 KEY(默认 default)
#   三级查找 id,再映射到文件路径注入脚本。未定义 KEYS 时回退到
#   PASSPHRASE_FILE 直配。

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="${PBS_COLD_CONF:-$SCRIPT_DIR/pbs-cold-manager.conf}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

usage() {
    cat >&2 <<EOF
用法: $0 backup [目标...] | restore <目标> [源] | list
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
SOURCES=(${SOURCES[@]+"${SOURCES[@]}"})
DEFAULT_BACKUP_SCRIPT="${DEFAULT_BACKUP_SCRIPT:-pbs-cold-backup-7z.sh}"
DEFAULT_RESTORE_SCRIPT="${DEFAULT_RESTORE_SCRIPT:-pbs-cold-restore-7z.sh}"

# 源路径 → 变量名片段(/ 与 - 转 _)
slugify() {
    local s="${1//\//_}"
    echo "${s//-/_}"
}

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

# 源×目标三级查找: <目标>_<源slug>_<变量> → <目标>_<变量> → 共享层
rel_var() {
    local tv="${1}_${2}_${3}"
    if [ -n "${!tv:-}" ]; then
        echo "${!tv}"
    else
        effective_var "$1" "$3"
    fi
}

# 密钥解析:密钥 id 三级查找(<目标>_<源slug>_KEY → <目标>_KEY → 共享 KEY,
# 默认 default),再经 KEYS 注册表映射到文件路径;
# 未定义 KEYS 注册表时回退到 PASSPHRASE_FILE 直配。
resolve_key() {
    local t="$1" slug="$2" kid path
    if declare -p KEYS >/dev/null 2>&1 && [ "${#KEYS[@]}" -gt 0 ]; then
        kid=$(rel_var "$t" "$slug" KEY)
        kid="${kid:-default}"
        path="${KEYS[$kid]:-}"
        if [ -z "$path" ]; then
            log "ERROR: [$t@$slug] 密钥 id '$kid' 未在 KEYS 注册表中定义"
            return 1
        fi
        echo "$path"
    else
        path=$(effective_var "$t" PASSPHRASE_FILE)
        if [ -z "$path" ]; then
            log "ERROR: [$t@$slug] 未配置密钥(KEYS 注册表或 PASSPHRASE_FILE)"
            return 1
        fi
        echo "$path"
    fi
}

# 某源的目标列表(未配置 <源slug>_TARGETS 收窄时 = 全部 TARGETS),空格分隔
src_targets() {
    local slug vn
    slug=$(slugify "$1")
    vn="${slug}_TARGETS"
    if declare -p "$vn" >/dev/null 2>&1; then
        declare -n _st_arr="$vn"
        echo "${_st_arr[@]}"
    else
        echo ${TARGETS[@]+"${TARGETS[@]}"}
    fi
}

# 某目标属于哪些源(逐行输出)
sources_for_target() {
    local t="$1" src st
    for src in ${SOURCES[@]+"${SOURCES[@]}"}; do
        st=" $(src_targets "$src") "
        [[ "$st" == *" $t "* ]] && echo "$src"
    done
}

# 组装环境并调用目标脚本: run_target <目标> backup|restore [额外 VAR=val ...]
# 额外参数优先级最高(空值表示删除该变量)
run_target() {
    local t="$1" mode="$2"
    shift 2
    local sv script
    if [ "$mode" = backup ]; then
        sv="${t}_BACKUP_SCRIPT"
        script=$(resolve_script "${!sv:-$DEFAULT_BACKUP_SCRIPT}")
    else
        sv="${t}_RESTORE_SCRIPT"
        script=$(resolve_script "${!sv:-$DEFAULT_RESTORE_SCRIPT}")
    fi
    [ -r "$script" ] || { log "ERROR: [$t] 脚本不可读: $script"; return 1; }

    local -A envmap=()
    local var val kv
    for var in "${PASSTHRU_VARS[@]}"; do
        val=$(effective_var "$t" "$var")
        [ -n "$val" ] && envmap[$var]="$val"
    done
    for kv in "$@"; do
        var="${kv%%=*}"; val="${kv#*=}"
        if [ -n "$val" ]; then
            envmap[$var]="$val"
        else
            unset "envmap[$var]"
        fi
    done
    local -a env_args=()
    for var in "${!envmap[@]}"; do
        env_args+=("$var=${envmap[$var]}")
    done
    log "[$t] $mode → $(basename "$script") (S3: ${envmap[S3_BUCKET]:-?}/${envmap[S3_PREFIX]:-?})"
    env "${env_args[@]}" bash "$script"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
    backup)
        requested=("$@")
        for t in ${requested[@]+"${requested[@]}"}; do check_target "$t"; done
        [ ${#SOURCES[@]} -gt 0 ] || { log "ERROR: 配置中没有 SOURCES"; exit 1; }

        failed=()
        did=0
        RUN_TS=$(date +%Y%m%d-%H%M%S)
        for src in "${SOURCES[@]}"; do
            slug=$(slugify "$src")
            # 本源目标列表 ∩ 请求子集
            run_list=()
            for t in $(src_targets "$src"); do
                if [ ${#requested[@]} -eq 0 ] || [[ " ${requested[*]} " == *" $t "* ]]; then
                    run_list+=("$t")
                fi
            done
            [ ${#run_list[@]} -eq 0 ] && continue

            log "===== source: $src (targets: ${run_list[*]}) ====="
            # 同一源下两目标 bucket/prefix 相同会写到同一链目录,互相覆盖
            declare -A seen_roots=()
            for t in "${run_list[@]}"; do
                root="$(effective_var "$t" S3_BUCKET)/$(effective_var "$t" S3_PREFIX)"
                if [ -n "${seen_roots[$root]:-}" ]; then
                    log "ERROR: [$t@$src] 与 [${seen_roots[$root]}@$src] 的 S3 bucket/prefix 相同 ($root),链会互相覆盖,跳过"
                    failed+=("$t@$src")
                    continue
                fi
                seen_roots[$root]="$t"
                keyfile=$(resolve_key "$t" "$slug") || { failed+=("$t@$src"); continue; }
                did=$((did + 1))
                # 同一 BACKUP_TS → 同源各目标复用同名快照(首个目标创建)
                if ! run_target "$t" backup \
                        "ZVOL=$src" \
                        "BACKUP_TS=$RUN_TS" \
                        "PASSPHRASE_FILE=$keyfile"; then
                    log "ERROR: [$t@$src] backup failed, continuing"
                    failed+=("$t@$src")
                fi
            done
        done

        [ "$did" -eq 0 ] && { log "ERROR: 没有任何 (源,目标) 组合可执行"; exit 1; }
        if [ ${#failed[@]} -gt 0 ]; then
            log "ERROR: backup finished with ${#failed[@]} failed pair(s): ${failed[*]}"
            exit 1
        fi
        log "Backup done: $did pair(s) all succeeded"
        ;;
    restore)
        [ $# -ge 1 ] && [ $# -le 2 ] || usage
        t="$1"
        check_target "$t"
        mapfile -t t_sources < <(sources_for_target "$t")
        [ ${#t_sources[@]} -gt 0 ] || { log "ERROR: 目标 $t 不属于任何源"; exit 1; }
        if [ $# -eq 2 ]; then
            src="$2"
            [[ " ${t_sources[*]} " == *" $src "* ]] || {
                log "ERROR: 源 '$src' 未配置到目标 $t(可选: ${t_sources[*]})"
                exit 1
            }
        elif [ ${#t_sources[@]} -eq 1 ]; then
            src="${t_sources[0]}"
        else
            log "ERROR: 目标 $t 有 ${#t_sources[@]} 个源,恢复必须指定: restore $t <源>"
            printf '  %s\n' "${t_sources[@]}" >&2
            exit 1
        fi
        slug=$(slugify "$src")
        keyfile=$(resolve_key "$t" "$slug") || exit 1
        # DEST_ZVOL 三级查找: <目标>_<源slug>_DEST_ZVOL → <目标>_DEST_ZVOL → 共享层
        dz=$(rel_var "$t" "$slug" DEST_ZVOL)
        log "===== restore: $t @ $src → ${dz:-默认DEST_ZVOL} ====="
        run_target "$t" restore \
            "DEST_ZVOL=$dz" \
            "PASSPHRASE_FILE=$keyfile"
        ;;
    list)
        for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
            bv="${t}_BACKUP_SCRIPT"; rv="${t}_RESTORE_SCRIPT"
            bshow="${!bv:-$DEFAULT_BACKUP_SCRIPT}"; [ -z "${!bv:-}" ] && bshow="$bshow (默认)"
            rshow="${!rv:-$DEFAULT_RESTORE_SCRIPT}"; [ -z "${!rv:-}" ] && rshow="$rshow (默认)"
            if declare -p KEYS >/dev/null 2>&1 && [ "${#KEYS[@]}" -gt 0 ]; then
                kv="${t}_KEY"; kid="${!kv:-${KEY:-default}}"
                kshow="${kid} → ${KEYS[$kid]:-未注册!}"
            else
                kshow="$(effective_var "$t" PASSPHRASE_FILE)"
            fi
            printf '%s\n  backup : %s\n  restore: %s\n  s3     : %s/%s @ %s\n  key    : %s\n  sources: %s\n' \
                "$t" "$bshow" "$rshow" \
                "$(effective_var "$t" S3_BUCKET)" \
                "$(effective_var "$t" S3_PREFIX)" \
                "$(effective_var "$t" S3_ENDPOINT)" \
                "$kshow" \
                "$(sources_for_target "$t" | tr '\n' ' ')"
        done
        ;;
    *)
        usage
        ;;
esac

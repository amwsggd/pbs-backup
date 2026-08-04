#!/bin/bash
set -euo pipefail

# pbs-cold-backup-7z.sh — PBS datastore 冷备份(7z 分卷版)
#
# 7z 封装层口令，备份端和恢复端须保持一致
#
# 7z 封装层口令，备份端和恢复端须保持一致
#
# 分卷条目参数与容量校验

# ======= 配置区(均可用同名环境变量覆盖) =======
ZVOL="${ZVOL:-tank/pbs-datastore}"
S3_BUCKET="${S3_BUCKET:-baidu-pbs}"
S3_PREFIX="${S3_PREFIX:-pbs-cold-backup-7z}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.openlist.example.com}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-/etc/pbs-cold-backup/passphrase}"

# 7z 封装层口令，备份端和恢复端须保持一致
WEAK_PASS="${WEAK_PASS:-canon2024}"

VOL_SIZE_MB="${VOL_SIZE_MB:-1024}"      # 归档参数
# 分卷条目参数与容量校验
CLIPS_PER_VOL="${CLIPS_PER_VOL:-}"      # 归档参数
CLIP_MIN_MB="${CLIP_MIN_MB:-}"
CLIP_MAX_MB="${CLIP_MAX_MB:-}"
TMP_DIR="${TMP_DIR:-/tank/pbs-cold-backup-tmp}"
ENTRY_DIR="${ENTRY_DIR:-DCIM/100CANON}" # 包内目录
# 7z 归档流程说明
VOL_BASE="${VOL_BASE:-DCIM_$(date +%Y%m%d)}"

KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-7}"
FULL_EVERY="${FULL_EVERY:-7}"
KEEP_CHAINS="${KEEP_CHAINS:-3}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
SEVENZ="${SEVENZ:-7zz}"
HEADER_SEED="${HEADER_SEED:-640}"   # 当前容器开销估计
PAD_SLACK="${PAD_SLACK:-128}"       # 卷尾预留空间

CLIP_NAME_FORMAT='MVI_%05d.MOV'
COMPRESS_FILE_NAME_FORMAT='%s.7z.%05d'

# 为归档条目生成稳定的时间戳序列
if [ -z "$CLIPS_PER_VOL" ]; then
    CLIPS_PER_VOL=$(( (VOL_SIZE_MB + 80) / 160 ))
    [ "$CLIPS_PER_VOL" -lt 2 ] && CLIPS_PER_VOL=2
    [ "$CLIPS_PER_VOL" -gt 24 ] && CLIPS_PER_VOL=24
fi
if [ -z "$CLIP_MIN_MB" ]; then
    CLIP_MIN_MB=$(( VOL_SIZE_MB * 7 / (CLIPS_PER_VOL * 10) ))
    [ "$CLIP_MIN_MB" -lt 2 ] && CLIP_MIN_MB=2
fi
if [ -z "$CLIP_MAX_MB" ]; then
    CLIP_MAX_MB=$(( VOL_SIZE_MB * 13 / (CLIPS_PER_VOL * 10) ))
    [ "$CLIP_MAX_MB" -gt 255 ] && CLIP_MAX_MB=255
fi
# =======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 通用重试函数
retry() {
    local max_attempts="${RETRY_ATTEMPTS}"
    local delay="${RETRY_DELAY}"
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if "$@"; then
            return 0
        fi
        log "WARN: command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
    log "ERROR: command failed after $max_attempts attempts: $*"
    return 1
}

# 列出 S3 上当前链根目录下的所有全量链(CHAIN_ROOT 在主流程中赋值,含 SRC_TAG 隔离)
list_s3_chains() {
    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/" \
        --delimiter "/" \
        --endpoint-url "${S3_ENDPOINT}" \
        --query 'CommonPrefixes[].Prefix' \
        --output json |
        jq -r '.[]' |
        sed "s#^${CHAIN_ROOT}/##" |
        sed 's#/$##' |
        sort
}

# 获取当前最新的全量链目录
current_s3_chain() {
    list_s3_chains | tail -n 1
}

# 统计某链目录下的增量(inc-*)目录数
count_chain_incs() {
    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/${1}/" \
        --delimiter "/" \
        --endpoint-url "${S3_ENDPOINT}" \
        --query 'CommonPrefixes[].Prefix' \
        --output json |
        jq -r '.[]' |
        grep -c '/inc-' || true
}

# 删除旧的全量链目录，只保留最近的 KEEP_CHAINS 个
cleanup_old_s3_chains() {
    log "Cleaning up old S3 chains, keeping last ${KEEP_CHAINS}"
    local chains
    chains=$(list_s3_chains)
    if [ -z "$chains" ]; then
        return 0
    fi

    echo "$chains" | head -n -${KEEP_CHAINS} | while read -r chain; do
        log "Deleting old S3 chain: ${chain}"
        retry aws s3 rm "s3://${S3_BUCKET}/${CHAIN_ROOT}/${chain}/" \
            --recursive \
            --endpoint-url="${S3_ENDPOINT}"
    done
}

# 配置 AWS CLI 以适配 Openlist 的 S3 兼容层
configure_aws_cli() {
    aws configure set default.s3.max_concurrent_requests 1
    aws configure set default.s3.addressing_style path
    aws configure set default.s3.signature_version s3
}

# 创建 zfs 发送流
zfs_send_stream() {
    local snapshot="$1"
    local prev_snapshot="${2:-}"
    if [ -z "$prev_snapshot" ]; then
        zfs send -c "$snapshot"
    else
        zfs send -c -i "$prev_snapshot" "$snapshot"
    fi
}

# 压缩加密流(真加密层,与旧方案一致)
compress_encrypt_stream() {
    zstd -3 | \
        gpg --symmetric --cipher-algo AES256 --compress-algo 0 \
            --passphrase-file "${PASSPHRASE_FILE}" --batch --yes
}

# 分卷条目参数与容量校验
estimate_stream_bytes() {
    local snapshot="$1"
    local prev_snapshot="${2:-}"
    local val=""
    if [ -z "$prev_snapshot" ]; then
        val=$(zfs get -Hpo value referenced "$snapshot" 2>/dev/null || true)
    else
        # prev 可为快照(fs@snap)或书签(fs#bm),统一取尾段
        val=$(zfs get -Hpo value "written@${prev_snapshot##*[@#]}" "$snapshot" 2>/dev/null || true)
    fi
    case "$val" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$val" ;;
    esac
}

# 为归档条目生成稳定的时间戳序列
SHOT_BASE=$(date -d "${VOL_BASE##*_} 10:00:00" +%s 2>/dev/null || echo 1754000000)
clip_mtime() { echo $(( SHOT_BASE + ($1 - 1) * 317 )); }   # 归档参数
dir_mtime()  { echo $(( SHOT_BASE - 86400 )); }

# 分卷条目参数与容量校验
gen_clip_quotas() { # $1=本卷载荷目标字节;输出空格分隔的字节数列表
    local total="$1" n="$CLIPS_PER_VOL"
    local lo=$((CLIP_MIN_MB * 1048576)) hi=$((CLIP_MAX_MB * 1048576))
    local sum=0 i s rest remain lo2 hi2 lo_mb hi_mb
    for i in $(seq 1 $((n - 1))); do
        rest=$((total - sum))
        remain=$((n - i))
        # 分卷条目参数与容量校验
        lo2=$((rest - hi * remain)); [ "$lo2" -lt "$lo" ] && lo2=$lo
        hi2=$((rest - lo * remain)); [ "$hi2" -gt "$hi" ] && hi2=$hi
        lo_mb=$(( (lo2 + 1048575) / 1048576 ))
        hi_mb=$(( hi2 / 1048576 ))
        s=$(( (lo_mb + RANDOM % (hi_mb - lo_mb + 1)) * 1048576 ))
        sum=$((sum + s))
        printf '%d ' "$s"
    done
    printf '%d\n' "$((total - sum))"
}

# 分卷大小与容器开销处理
cut_clip() { # $1=字节数 $2=目标文件
    local bytes="$1" dest="$2"
    local mb=$((bytes / 1048576)) rem=$((bytes % 1048576))
    if ! dd bs=1M count="$mb" iflag=fullblock of="$dest" 2>/dev/null; then
        return 1
    fi
    if [ "$rem" -gt 0 ]; then
        head -c "$rem" >> "$dest" || return 1
    fi
}

# 分卷条目参数与容量校验
pack_and_upload_volumes() {
    local s3_subpath="$1"
    local run_dir="$2"
    local vol_base="$3"

    # 分卷条目参数与容量校验
    if [ "$CLIP_MIN_MB" -lt 2 ] || [ "$CLIP_MAX_MB" -gt 255 ]; then
        log "ERROR: CLIP_MIN_MB/CLIP_MAX_MB 必须在 [2,255] 内(7z 长度编码同档要求)"
        return 1
    fi
    # 分卷条目参数与容量校验
    local vol_target=$(( VOL_SIZE_MB * 1048576 ))
    if [ $((CLIP_MIN_MB * 1048576 * CLIPS_PER_VOL)) -gt "$vol_target" ] || \
       [ $((CLIP_MAX_MB * 1048576 * CLIPS_PER_VOL)) -lt "$vol_target" ]; then
        log "ERROR: 片段配置无法凑出每卷 ${vol_target}B"
        return 1
    fi
    log "Volume structure: ${CLIPS_PER_VOL} clip(s)/vol, clip range ${CLIP_MIN_MB}-${CLIP_MAX_MB}MB"

    local clip_idx=1 vol_idx=1 eof=0
    local stage_dir="$run_dir/stage"
    local hat=$HEADER_SEED   # 当前容器开销估计

    while [ "$eof" -eq 0 ]; do
        # 分卷大小与容器开销处理
        local quotas
        quotas=$(gen_clip_quotas $(( vol_target - hat - PAD_SLACK )))

        rm -rf "$stage_dir"
        mkdir -p "$stage_dir/${ENTRY_DIR}"
        touch -d "@$(dir_mtime)" "$stage_dir/${ENTRY_DIR}" "$stage_dir/${ENTRY_DIR%/*}"

        local vol_bytes=0 quota got_bytes
        # 分卷大小与容器开销处理
        for quota in $quotas; do
            local clip_name clip_path
            clip_name=$(printf $CLIP_NAME_FORMAT "$clip_idx")
            clip_path="$stage_dir/${ENTRY_DIR}/${clip_name}"

            # 分卷条目参数与容量校验
            if ! cut_clip "$quota" "$clip_path"; then
                log "ERROR: failed while cutting clip ${clip_name}"
                return 1
            fi
            got_bytes=$(stat -c%s "$clip_path")
            touch -d "@$(clip_mtime "$clip_idx")" "$clip_path"

            if [ "$got_bytes" -eq 0 ]; then
                rm -f "$clip_path"
                eof=1
                break
            fi
            [ "$got_bytes" -lt "$quota" ] && eof=1

            vol_bytes=$((vol_bytes + got_bytes))
            clip_idx=$((clip_idx + 1))
            [ "$eof" -eq 1 ] && break
        done

        # 7z 归档流程说明
        if [ "$vol_bytes" -eq 0 ] && [ "$eof" -eq 1 ]; then
            rm -rf "$stage_dir"
            break
        fi

        # 分卷条目参数与容量校验
        local vol_name
        vol_name=$(printf $COMPRESS_FILE_NAME_FORMAT "$vol_base" "$vol_idx")
        (cd "$stage_dir" && "$SEVENZ" a -t7z -mx=0 -mhe=on -p"${WEAK_PASS}" \
            "$run_dir/$vol_name" "$ENTRY_DIR" >/dev/null)
        rm -rf "$stage_dir"

        # 分卷大小与容器开销处理
        local vol_size pad
        vol_size=$(stat -c%s "$run_dir/$vol_name")
        hat=$(( vol_size - vol_bytes ))        # 当前容器开销估计
        if [ "$eof" -eq 0 ]; then
            pad=$(( vol_target - vol_size ))
            if [ "$pad" -gt 0 ]; then
                [ "$pad" -gt 1024 ] && \
                    log "WARN: ${vol_name} pad ${pad}B larger than expected"
                head -c "$pad" /dev/urandom >> "$run_dir/$vol_name"
            else
                log "WARN: ${vol_name} overshoots target by $((-pad))B, left unpadded"
            fi
        fi

        log "Uploading ${vol_name} ($(stat -c%s "$run_dir/$vol_name")B, $((vol_bytes / 1024 / 1024))M payload)"
        # 显式判失败:本函数跑在 if 条件的管道里,set -e 不生效,必须自己中断
        if ! retry aws s3 cp "$run_dir/$vol_name" \
            "s3://${S3_BUCKET}/${CHAIN_ROOT}/${s3_subpath}/${vol_name}" \
            --endpoint-url="${S3_ENDPOINT}" \
            --cli-read-timeout 0 \
            --cli-connect-timeout 600; then
            rm -f "$run_dir/$vol_name"
            log "ERROR: upload failed for ${vol_name}"
            return 1
        fi
        rm -f "$run_dir/$vol_name"
        vol_idx=$((vol_idx + 1))
    done

    log "Packed $((vol_idx - 1)) volume(s), $((clip_idx - 1)) clip(s) total"
}

# ======= 预检 =======
for cmd in "$SEVENZ" zstd gpg aws jq zfs; do
    command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: 找不到命令: $cmd"; exit 1; }
done
[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: 口令文件不可读: $PASSPHRASE_FILE"; exit 1; }
mkdir -p "$TMP_DIR"

configure_aws_cli

# ======= 快照与全量/增量判断 =======
# 两种模式:
#  A. 独立运行(默认):自建 ${SNAP_TAG:-pbs}-<ts> 快照,按本地快照计数定全量/增量
#  B. manager 多对多:注入 ANCHOR_SNAPSHOT=<源>@mgr-<目标> 固定锚点(每 源×目标 一个)。
#     本次先建 <锚点>-new 快照:无锚点/无链→全量直发,否则 send -i 锚点 取增量;
#     上传成功后 -new 改名接任锚点(旧锚点删),任一时刻每 源×目标 仅一份锚点快照。
#  上传失败(两种模式相同):删除本次创建的快照和本次上传到 S3 的内容(不动既有链
#  与旧锚点),日志记录后退出 1。
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
# 链根目录:多源共用同一 S3 前缀时按 SRC_TAG 隔离(独立运行为空,布局不变)
CHAIN_ROOT="${S3_PREFIX}${SRC_TAG:+/${SRC_TAG}}"

ANCHOR="${ANCHOR_SNAPSHOT:-}"
if [ -n "$ANCHOR" ]; then
    SNAPSHOT="${ANCHOR}-new"
    zfs destroy "$SNAPSHOT" 2>/dev/null || true   # 上次失败/崩溃的残留
    log "Creating snapshot ${SNAPSHOT} (anchor: ${ANCHOR})"
    zfs snapshot "$SNAPSHOT"
else
    SNAP_NAME="${SNAP_TAG:-pbs}-${TIMESTAMP}"
    SNAPSHOT="${ZVOL}@${SNAP_NAME}"
    log "Creating snapshot ${SNAPSHOT}"
    zfs snapshot "${SNAPSHOT}"
fi

DO_FULL=0
if [ -n "$ANCHOR" ]; then
    # B 模式:无锚点或无链→全量;否则链内每满 FULL_EVERY 次一次全量
    CHAIN_FOLDER=$(current_s3_chain)
    if ! zfs list "$ANCHOR" >/dev/null 2>&1; then
        DO_FULL=1
    elif [ -z "$CHAIN_FOLDER" ]; then
        DO_FULL=1
    else
        INC_COUNT=$(count_chain_incs "$CHAIN_FOLDER")
        [ $(( (INC_COUNT + 1) % FULL_EVERY )) -eq 0 ] && DO_FULL=1
    fi
    PREV_SNAP="$ANCHOR"
else
    # A 模式:本地快照计数(原逻辑)
    ALL_SNAPS=$(zfs list -t snapshot -H -o name -s creation \
        | grep "^${ZVOL}@${SNAP_TAG:-pbs}-" || true)
    SNAP_COUNT=$(echo "$ALL_SNAPS" | grep -c "^${ZVOL}@${SNAP_TAG:-pbs}-" || true)
    if [ "$SNAP_COUNT" -le 1 ]; then
        DO_FULL=1
    elif [ $((SNAP_COUNT % FULL_EVERY)) -eq 0 ]; then
        DO_FULL=1
    fi
    PREV_SNAP=$(echo "$ALL_SNAPS" | tail -n 2 | head -n 1)
fi

if [ "$DO_FULL" -eq 1 ]; then
    CHAIN_FOLDER="${TIMESTAMP}"
    S3_SUBPATH="${CHAIN_FOLDER}/full"
    PREV_SNAP=""
    THIS_RUN_S3PATH="${CHAIN_FOLDER}"
    log "Full backup: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"
else
    CHAIN_FOLDER="${CHAIN_FOLDER:-$(current_s3_chain)}"
    if [ -z "$CHAIN_FOLDER" ]; then
        log "ERROR: no existing full backup chain found, cannot do incremental"
        zfs destroy "$SNAPSHOT" && log "Deleted this run's snapshot ${SNAPSHOT}"
        exit 1
    fi
    S3_SUBPATH="${CHAIN_FOLDER}/inc-${TIMESTAMP}"
    THIS_RUN_S3PATH="${S3_SUBPATH}"
    log "Incremental backup: ${PREV_SNAP} -> ${SNAPSHOT} into chain ${CHAIN_FOLDER}"
fi

# 上传失败清理:删本次 S3 内容与本次快照(不动既有链与旧锚点)
fail_this_run() {
    log "ERROR: upload failed; deleting this run's S3 content and snapshot"
    if retry aws s3 rm "s3://${S3_BUCKET}/${CHAIN_ROOT}/${THIS_RUN_S3PATH}/" \
            --recursive --endpoint-url="${S3_ENDPOINT}"; then
        log "Deleted this run's S3 content: ${CHAIN_ROOT}/${THIS_RUN_S3PATH}/"
    else
        log "WARN: S3 cleanup incomplete, please remove s3://${S3_BUCKET}/${CHAIN_ROOT}/${THIS_RUN_S3PATH}/ manually"
    fi
    if zfs destroy "$SNAPSHOT"; then
        log "Deleted this run's snapshot ${SNAPSHOT}"
    else
        log "WARN: failed deleting snapshot ${SNAPSHOT}, please destroy it manually"
    fi
    log "ERROR: backup failed (this run's artifacts cleaned up)"
    exit 1
}

# 分卷条目参数与容量校验
EST_BYTES=$(estimate_stream_bytes "$SNAPSHOT" "$PREV_SNAP")
if [ "$EST_BYTES" -gt 0 ]; then
    log "Estimated stream: $((EST_BYTES / 1024 / 1024))M, ~$((EST_BYTES / VOL_SIZE_MB / 1024 / 1024 + 1)) volume(s)"
fi

# ======= 主流水线 =======
RUN_DIR=$(mktemp -d "${TMP_DIR}/run.XXXXXX")
cleanup_run() { rm -rf "$RUN_DIR"; }
trap cleanup_run EXIT

if ! zfs_send_stream "$SNAPSHOT" "$PREV_SNAP" | \
        compress_encrypt_stream | \
        pack_and_upload_volumes "$S3_SUBPATH" "$RUN_DIR" "$VOL_BASE"; then
    fail_this_run
fi

log "Uploaded: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"

# 清理旧的全量链
cleanup_old_s3_chains

# 本地锚点/快照维护
if [ -n "$ANCHOR" ]; then
    # B 模式:新快照改名接任锚点(旧锚点删除;此后每 源×目标 仍只有一份锚点)
    if zfs list "$ANCHOR" >/dev/null 2>&1; then
        zfs destroy "$ANCHOR"
    fi
    zfs rename "$SNAPSHOT" "$ANCHOR"
    log "Anchor snapshot updated: ${ANCHOR}"
else
    # A 模式:按 KEEP_SNAPSHOTS 清理本地旧快照
    log "Cleaning up local snapshots"
    echo "$ALL_SNAPS" | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy
fi

log "Done"

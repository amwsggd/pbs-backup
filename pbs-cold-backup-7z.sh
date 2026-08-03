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
CLIPS_PER_VOL="${CLIPS_PER_VOL:-5}"     # 归档参数
# 分卷条目参数与容量校验
CLIP_MIN_MB="${CLIP_MIN_MB:-150}"
CLIP_MAX_MB="${CLIP_MAX_MB:-255}"
TMP_DIR="${TMP_DIR:-/tank/pbs-cold-backup-tmp}"
ENTRY_DIR="${ENTRY_DIR:-DCIM/100CANON}" # 包内目录
# 7z 归档流程说明
VOL_BASE="${VOL_BASE:-DCIM_$(date +%Y%m%d)}"

KEEP_SNAPSHOTS=7
FULL_EVERY=7
KEEP_CHAINS=3
RETRY_ATTEMPTS=3
RETRY_DELAY=5
SEVENZ="${SEVENZ:-7zz}"
HEADER_SEED="${HEADER_SEED:-640}"   # 当前容器开销估计
PAD_SLACK="${PAD_SLACK:-128}"       # 卷尾预留空间
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

# 列出 S3 上的所有全量链根目录
list_s3_chains() {
    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}/" \
        --delimiter "/" \
        --endpoint-url "${S3_ENDPOINT}" \
        --query 'CommonPrefixes[].Prefix' \
        --output json |
        jq -r '.[]' |
        sed "s#^${S3_PREFIX}/##" |
        sed 's#/$##' |
        sort
}

# 获取当前最新的全量链目录
current_s3_chain() {
    list_s3_chains | tail -n 1
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
        retry aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${chain}/" \
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
        val=$(zfs get -Hpo value "written@${prev_snapshot#*@}" "$snapshot" 2>/dev/null || true)
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
            clip_name=$(printf 'MVI_%05d.MOV' "$clip_idx")
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
        vol_name=$(printf '%s.7z.%03d' "$vol_base" "$vol_idx")
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
        retry aws s3 cp "$run_dir/$vol_name" \
            "s3://${S3_BUCKET}/${S3_PREFIX}/${s3_subpath}/${vol_name}" \
            --endpoint-url="${S3_ENDPOINT}" \
            --cli-read-timeout 0 \
            --cli-connect-timeout 600
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

# ======= 创建本地快照 =======
SNAP_NAME="pbs-$(date +%Y%m%d-%H%M%S)"
SNAPSHOT="${ZVOL}@${SNAP_NAME}"
log "Creating snapshot ${SNAPSHOT}"
zfs snapshot "${SNAPSHOT}"

# 列出所有本地快照
ALL_SNAPS=$(zfs list -t snapshot -H -o name -s creation | grep "^${ZVOL}@pbs-" || true)
SNAP_COUNT=$(echo "$ALL_SNAPS" | grep -c "^${ZVOL}@pbs-" || true)

# 判断全量还是增量
DO_FULL=0
if [ "$SNAP_COUNT" -le 1 ]; then
    DO_FULL=1
elif [ $((SNAP_COUNT % FULL_EVERY)) -eq 0 ]; then
    DO_FULL=1
fi

# 时间戳用于文件夹名和文件名
TIMESTAMP="${SNAP_NAME#pbs-}"

if [ "$DO_FULL" -eq 1 ]; then
    CHAIN_FOLDER="${TIMESTAMP}"
    S3_SUBPATH="${CHAIN_FOLDER}/full"
    PREV_SNAP=""
    log "Full backup: s3://${S3_BUCKET}/${S3_PREFIX}/${S3_SUBPATH}/"
else
    CHAIN_FOLDER=$(current_s3_chain)
    if [ -z "$CHAIN_FOLDER" ]; then
        log "ERROR: no existing full backup chain found, cannot do incremental"
        exit 1
    fi
    S3_SUBPATH="${CHAIN_FOLDER}/inc-${TIMESTAMP}"
    PREV_SNAP=$(echo "$ALL_SNAPS" | tail -n 2 | head -n 1)
    log "Incremental backup: ${PREV_SNAP} -> ${SNAPSHOT} into chain ${CHAIN_FOLDER}"
fi

# 分卷条目参数与容量校验
EST_BYTES=$(estimate_stream_bytes "$SNAPSHOT" "$PREV_SNAP")
if [ "$EST_BYTES" -gt 0 ]; then
    log "Estimated stream: $((EST_BYTES / 1024 / 1024))M, ~$((EST_BYTES / VOL_SIZE_MB / 1024 / 1024 + 1)) volume(s)"
fi

# ======= 主流水线 =======
RUN_DIR=$(mktemp -d "${TMP_DIR}/run.XXXXXX")
cleanup_run() { rm -rf "$RUN_DIR"; }
trap cleanup_run EXIT

set -o pipefail
zfs_send_stream "$SNAPSHOT" "$PREV_SNAP" | \
    compress_encrypt_stream | \
    pack_and_upload_volumes "$S3_SUBPATH" "$RUN_DIR" "$VOL_BASE"

log "Uploaded: s3://${S3_BUCKET}/${S3_PREFIX}/${S3_SUBPATH}/"

# 清理旧的全量链
cleanup_old_s3_chains

# 清理本地旧快照
log "Cleaning up local snapshots"
echo "$ALL_SNAPS" | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy

log "Done"

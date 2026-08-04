#!/bin/bash
set -euo pipefail

# ======= 配置区(均可用同名环境变量覆盖;默认值与原硬编码一致) =======
ZVOL="${ZVOL:-tank/pbs-datastore}"
S3_BUCKET="${S3_BUCKET:-baidu-pbs}"
S3_PREFIX="${S3_PREFIX:-pbs-cold-backup}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.openlist.example.com}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-/etc/pbs-cold-backup/passphrase}"
PART_SIZE="${PART_SIZE:-1G}"
PART_FORMAT="${PART_FORMAT:-x%05d.zfs.zst.gpg}"
TMP_DIR="${TMP_DIR:-/tank/pbs-cold-backup-tmp}"
KEEP_SNAPSHOTS=7
FULL_EVERY=7
KEEP_CHAINS=3
RETRY_ATTEMPTS=3
RETRY_DELAY=5
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

# 把人类可读大小转换为字节数
parse_size() {
    numfmt --from=iec "$1"
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

# 压缩加密流
compress_encrypt_stream() {
    zstd -3 | \
        gpg --symmetric --cipher-algo AES256 --compress-algo 0 \
            --passphrase-file "${PASSPHRASE_FILE}" --batch --yes
}

# 将 stdin 拆分为 PART_SIZE 大小的分片，逐个上传并删除，支持重试
upload_parts() {
    local s3_subpath="$1"
    local part_idx=0

    mkdir -p "${TMP_DIR}"
    local part_tmp_dir
    part_tmp_dir=$(mktemp -d "${TMP_DIR}/parts.XXXXXX")

    local part_size_bytes
    part_size_bytes=$(parse_size "${PART_SIZE}")
    local part_size_mb=$((part_size_bytes / 1024 / 1024))

    while true; do
        local part_file
        part_file=$(printf "${PART_FORMAT}" "$part_idx")
        local part_path="${part_tmp_dir}/${part_file}"

        # 从 stdin 读取 PART_SIZE 到临时文件
        if ! dd bs=1M count="${part_size_mb}" iflag=fullblock of="${part_path}" 2>/dev/null; then
            rm -f "${part_path}"
            break
        fi

        # 没有读到数据则结束
        if [ ! -s "${part_path}" ]; then
            rm -f "${part_path}"
            break
        fi

        # 上传该分片，失败自动重试；Openlist 限速后 read timeout 设 0 避免中断
        log "Uploading part ${part_file}"
        retry aws s3 cp "${part_path}" "s3://${S3_BUCKET}/${CHAIN_ROOT}/${s3_subpath}/${part_file}" \
            --endpoint-url="${S3_ENDPOINT}" \
            --cli-read-timeout 0 \
            --cli-connect-timeout 600

        rm -f "${part_path}"
        part_idx=$((part_idx + 1))
    done

    rm -rf "${part_tmp_dir}"
}

# 上传数据流
upload_stream() {
    local snapshot="$1"
    local prev_snapshot="${2:-}"
    local s3_subpath="$3"

    zfs_send_stream "$snapshot" "$prev_snapshot" | \
        compress_encrypt_stream | \
        upload_parts "$s3_subpath"
}

# 创建本地快照前，先确保 AWS CLI 已配置
configure_aws_cli

# ======= 快照与全量/增量判断 =======
# 两种模式:
#  A. 独立运行(默认):自建 ${SNAP_TAG:-pbs}-<ts> 快照,按本地快照计数定全量/增量
#  B. manager 多目标:EXISTING_SNAPSHOT 复用共享快照(不建不删) +
#     ANCHOR_BOOKMARK_PREFIX 按"源×目标"书签定节奏/作增量锚点(send -i 支持书签)
#     + BACKUP_TS 统一时间戳 + SRC_TAG 链目录按源隔离
TIMESTAMP="${BACKUP_TS:-$(date +%Y%m%d-%H%M%S)}"
if [ -n "${EXISTING_SNAPSHOT:-}" ]; then
    SNAPSHOT="$EXISTING_SNAPSHOT"
    log "Reusing existing snapshot ${SNAPSHOT}"
else
    SNAP_NAME="${SNAP_TAG:-pbs}-${TIMESTAMP}"
    SNAPSHOT="${ZVOL}@${SNAP_NAME}"
    log "Creating snapshot ${SNAPSHOT}"
    zfs snapshot "${SNAPSHOT}"
fi

# 链根目录:多源共用同一 S3 前缀时按 SRC_TAG 隔离(独立运行为空,布局不变)
CHAIN_ROOT="${S3_PREFIX}${SRC_TAG:+/${SRC_TAG}}"

DO_FULL=0
if [ -n "${ANCHOR_BOOKMARK_PREFIX:-}" ]; then
    # B 模式:书签计数定节奏(0 或 FULL_EVERY 倍数→全量),最新书签为增量锚点
    ALL_BMS=$(zfs list -t bookmark -H -o name -s creation \
        | grep "^${ZVOL}#${ANCHOR_BOOKMARK_PREFIX}-" || true)
    BM_COUNT=$(echo "$ALL_BMS" | grep -c "^${ZVOL}#${ANCHOR_BOOKMARK_PREFIX}-" || true)
    [ $((BM_COUNT % FULL_EVERY)) -eq 0 ] && DO_FULL=1
    PREV_SNAP=$(echo "$ALL_BMS" | tail -n 1)
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
    # 新全量：创建新链
    CHAIN_FOLDER="${TIMESTAMP}"
    S3_SUBPATH="${CHAIN_FOLDER}/full"
    PREV_SNAP=""
    log "Full backup: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"
    upload_stream "${SNAPSHOT}" "" "${S3_SUBPATH}"
else
    # 增量：放入当前最新的全量链
    CHAIN_FOLDER=$(current_s3_chain)
    if [ -z "$CHAIN_FOLDER" ]; then
        log "ERROR: no existing full backup chain found, cannot do incremental"
        exit 1
    fi
    S3_SUBPATH="${CHAIN_FOLDER}/inc-${TIMESTAMP}"
    log "Incremental backup: ${PREV_SNAP} -> ${SNAPSHOT} into chain ${CHAIN_FOLDER}"
    upload_stream "${SNAPSHOT}" "${PREV_SNAP}" "${S3_SUBPATH}"
fi

log "Uploaded: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"

# 清理旧的全量链
cleanup_old_s3_chains

# 本地锚点维护:B 模式建"源×目标"书签并修剪(书签不占空间,快照可安全轮换);
# A 模式且快照为自建时,按 KEEP_SNAPSHOTS 清理本地旧快照
if [ -n "${ANCHOR_BOOKMARK_PREFIX:-}" ]; then
    log "Creating anchor bookmark ${ZVOL}#${ANCHOR_BOOKMARK_PREFIX}-${TIMESTAMP}"
    zfs bookmark "${SNAPSHOT}" "${ZVOL}#${ANCHOR_BOOKMARK_PREFIX}-${TIMESTAMP}"
    zfs list -t bookmark -H -o name -s creation \
        | grep "^${ZVOL}#${ANCHOR_BOOKMARK_PREFIX}-" \
        | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy
elif [ -z "${EXISTING_SNAPSHOT:-}" ]; then
    log "Cleaning up local snapshots"
    echo "$ALL_SNAPS" | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy
fi

log "Done"

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
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-7}"
FULL_EVERY="${FULL_EVERY:-7}"
KEEP_CHAINS="${KEEP_CHAINS:-3}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
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

# 链内最近一次备份对应的快照时间戳:有 inc 取最新 inc 的 ts,否则为链目录名(全量 ts)
chain_base_ts() {
    local latest
    latest=$(aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/${1}/" \
        --delimiter "/" \
        --endpoint-url "${S3_ENDPOINT}" \
        --query 'CommonPrefixes[].Prefix' \
        --output json |
        jq -r '.[]' |
        sed 's#/$##' |
        awk -F/ '{print $NF}' |
        { grep '^inc-' || true; } |
        sort | tail -n 1)
    if [ -n "$latest" ]; then
        echo "${latest#inc-}"
    else
        echo "$1"
    fi
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
        # (显式判失败:本函数跑在 if 条件的管道里,set -e 不生效,必须自己中断)
        log "Uploading part ${part_file}"
        if ! retry aws s3 cp "${part_path}" "s3://${S3_BUCKET}/${CHAIN_ROOT}/${s3_subpath}/${part_file}" \
            --endpoint-url="${S3_ENDPOINT}" \
            --cli-read-timeout 0 \
            --cli-connect-timeout 600; then
            rm -f "${part_path}"
            rm -rf "${part_tmp_dir}"
            return 1
        fi

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
# 快照命名与旧版一致:<源>@${SNAP_TAG:-pbs}-<ts>。多目标时 manager 为同源各
# 目标注入同一 BACKUP_TS → 同名快照已存在则复用(同源同轮不重复建)。
# 全量/增量与增量基以 S3 链为准(链目录名=全量 ts,inc-<ts>=增量 ts,
# 恰好对应快照名):无链→全量;链内 inc 满 FULL_EVERY→全量开新链;否则以链内
# 最近条目对应快照为 send -i 增量基;基快照已被清理则回退全量。
# 失败处理(EXIT trap 兜底,覆盖上传失败以外的异常退出):
# 先保证本次创建的快照被删(本地操作必然完成),再尽力删本次 S3 内容
# (全量=新链目录,增量=该 inc 目录);既有链与既有快照一律不动。
TIMESTAMP="${BACKUP_TS:-$(date +%Y%m%d-%H%M%S)}"
# 链根目录:多源共用同一 S3 前缀时按 SRC_TAG 隔离(独立运行为空,布局不变)
CHAIN_ROOT="${S3_PREFIX}${SRC_TAG:+/${SRC_TAG}}"

SNAPSHOT="${ZVOL}@${SNAP_TAG:-pbs}-${TIMESTAMP}"
SNAPSHOT_NEW=0
if zfs list "$SNAPSHOT" >/dev/null 2>&1; then
    log "Reusing existing snapshot ${SNAPSHOT}"
else
    log "Creating snapshot ${SNAPSHOT}"
    zfs snapshot "${SNAPSHOT}"
    SNAPSHOT_NEW=1
fi

BACKUP_OK=0
THIS_RUN_S3PATH=""
cleanup_on_exit() {
    [ "$BACKUP_OK" = 1 ] && return 0
    if [ "$SNAPSHOT_NEW" = 1 ]; then
        zfs destroy "$SNAPSHOT" 2>/dev/null && \
            log "Deleted this run's snapshot ${SNAPSHOT}"
    fi
    if [ -n "$THIS_RUN_S3PATH" ]; then
        if retry aws s3 rm "s3://${S3_BUCKET}/${CHAIN_ROOT}/${THIS_RUN_S3PATH}/" \
                --recursive --endpoint-url="${S3_ENDPOINT}"; then
            log "Deleted this run's S3 content: ${CHAIN_ROOT}/${THIS_RUN_S3PATH}/"
        else
            log "WARN: S3 cleanup incomplete, please remove s3://${S3_BUCKET}/${CHAIN_ROOT}/${THIS_RUN_S3PATH}/ manually"
        fi
    fi
}
trap cleanup_on_exit EXIT

CHAIN_FOLDER=$(current_s3_chain)
DO_FULL=0
PREV_SNAP=""
if [ -z "$CHAIN_FOLDER" ]; then
    DO_FULL=1
else
    INC_COUNT=$(count_chain_incs "$CHAIN_FOLDER")
    [ $(( (INC_COUNT + 1) % FULL_EVERY )) -eq 0 ] && DO_FULL=1
    PREV_SNAP="${ZVOL}@${SNAP_TAG:-pbs}-$(chain_base_ts "$CHAIN_FOLDER")"
    if [ "$DO_FULL" -eq 0 ] && [ "$PREV_SNAP" = "$SNAPSHOT" ]; then
        log "Nothing to do: incremental base equals current snapshot (${SNAPSHOT})"
        BACKUP_OK=1
        exit 0
    fi
    if [ "$DO_FULL" -eq 0 ] && ! zfs list "$PREV_SNAP" >/dev/null 2>&1; then
        log "WARN: base snapshot ${PREV_SNAP} no longer exists, falling back to full"
        DO_FULL=1
    fi
fi

if [ "$DO_FULL" -eq 1 ]; then
    CHAIN_FOLDER="${TIMESTAMP}"
    S3_SUBPATH="${CHAIN_FOLDER}/full"
    PREV_SNAP=""
    THIS_RUN_S3PATH="${CHAIN_FOLDER}"
    log "Full backup: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"
else
    S3_SUBPATH="${CHAIN_FOLDER}/inc-${TIMESTAMP}"
    THIS_RUN_S3PATH="${S3_SUBPATH}"
    log "Incremental backup: ${PREV_SNAP} -> ${SNAPSHOT} into chain ${CHAIN_FOLDER}"
fi

# 上传数据流
if ! upload_stream "${SNAPSHOT}" "${PREV_SNAP}" "${S3_SUBPATH}"; then
    log "ERROR: upload failed; deleting this run's snapshot and S3 content"
    exit 1
fi
BACKUP_OK=1

log "Uploaded: s3://${S3_BUCKET}/${CHAIN_ROOT}/${S3_SUBPATH}/"

# 清理旧的全量链
cleanup_old_s3_chains

# 本地快照修剪(与旧版一致,保留最近 KEEP_SNAPSHOTS 份)
log "Cleaning up local snapshots"
ALL_SNAPS=$(zfs list -t snapshot -H -o name -s creation \
    | grep "^${ZVOL}@${SNAP_TAG:-pbs}-" || true)
echo "$ALL_SNAPS" | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy

log "Done"

#!/bin/bash
set -euo pipefail

# ======= 配置区(均可用同名环境变量覆盖;默认值与原硬编码一致) =======
S3_BUCKET="${S3_BUCKET:-baidu-pbs}"
S3_PREFIX="${S3_PREFIX:-pbs-cold-backup}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.openlist.example.com}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-/etc/pbs-cold-backup/passphrase}"
DEST_ZVOL="${DEST_ZVOL:-tank/pbs-restore}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-6}"
RETRY_DELAY="${RETRY_DELAY:-5}"
# =======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

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
# 链根目录:多源共用同一 S3 前缀时按 SRC_TAG 隔离(独立运行为空,布局不变)
CHAIN_ROOT="${S3_PREFIX}"

list_s3_chains() {
    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/" \
        --delimiter "/" \
        --endpoint-url "${S3_ENDPOINT}" \
        --query 'CommonPrefixes[].Prefix' \
        --output json |
        jq -r '.[]?' |
        sed "s#^${CHAIN_ROOT}/##" |
        sed 's#/$##' |
        sort
}

# 列出某个目录下的所有分片文件
list_parts() {
    local subpath="$1"

    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/${subpath}/" \
        --endpoint-url="${S3_ENDPOINT}" \
        --query 'Contents[].Key' \
        --output json |
        jq -r '.[]?' |
        awk -F/ '{print $NF}' |
        grep '\.zfs\.zst\.gpg$' |
        sort
}

# 下载单个分片到临时文件，成功后输出 stdout
download_part() {
    local subpath="$1"
    local part="$2"

    local tmp
    tmp=$(mktemp)

    if ! aws s3api get-object \
        --bucket "${S3_BUCKET}" \
        --key "${CHAIN_ROOT}/${subpath}/${part}" \
        --endpoint-url="${S3_ENDPOINT}" \
        "$tmp" \
        >/dev/null
    then
        rm -f "$tmp"
        return 1
    fi

    cat "$tmp"

    rm -f "$tmp"
}

# 按顺序下载某个子路径下的所有分片，并合并到 stdout
stream_parts() {
    local subpath="$1"
    local parts
    parts=$(list_parts "$subpath")
    if [ -z "$parts" ]; then
        log "ERROR: no parts found in ${subpath}"
        return 1
    fi
    for part in $parts; do
        log "Downloading ${subpath}/${part}"

        if ! retry download_part "${subpath}" "${part}"; then
            log "ERROR: failed downloading ${subpath}/${part}"
            return 1
        fi
    done
}

# 从 S3 下载分片、解密、解压并 zfs receive
receive_from_s3() {
    local subpath="$1"
    local receive_flags="${2:-}"
    stream_parts "$subpath" | \
        gpg --ignore-mdc-error --decrypt --passphrase-file "${PASSPHRASE_FILE}" --batch --yes | \
        zstd -d | \
        zfs receive ${receive_flags} "${DEST_ZVOL}"
}

# 获取所有链
ALL_CHAINS=$(list_s3_chains)
if [ -z "$ALL_CHAINS" ]; then
    log "ERROR: no backup chains found in S3"
    exit 1
fi

# 找到最新包含 full/ 目录的链
LATEST_CHAIN=""
for chain in $ALL_CHAINS; do
    if [ -n "$(list_parts "${chain}/full" 2>/dev/null)" ]; then
        LATEST_CHAIN="$chain"
    fi
done

if [ -z "$LATEST_CHAIN" ]; then
    log "ERROR: no full backup found in any S3 chain"
    exit 1
fi

log "Latest full backup chain: ${LATEST_CHAIN}"

# 创建目标 zvol
if ! zfs list "${DEST_ZVOL}" >/dev/null 2>&1; then
    log "Creating destination zvol ${DEST_ZVOL}"
    zfs create -V 1T "${DEST_ZVOL}"
fi

# 接收全量
log "Restoring full backup from chain ${LATEST_CHAIN}"
receive_from_s3 "${LATEST_CHAIN}/full" "-F"

# 应用全量链下的所有增量目录(注意先 sed 去尾 slash 再取目录名,
# 否则 $NF 为空导致增量被静默跳过)
INCREMENTAL_DIRS=$(aws s3api list-objects-v2 \
    --bucket "${S3_BUCKET}" \
    --prefix "${CHAIN_ROOT}/${LATEST_CHAIN}/" \
    --delimiter "/" \
    --endpoint-url="${S3_ENDPOINT}" \
    --query 'CommonPrefixes[].Prefix' \
    --output json |
    jq -r '.[]?' |
    sed 's#/$##' |
    awk -F/ '{print $NF}' |
    grep '^inc-' |
    sort || true)

if [ -n "$INCREMENTAL_DIRS" ]; then
    log "Applying incremental backups from chain ${LATEST_CHAIN}"
    for inc_dir in $INCREMENTAL_DIRS; do
        log "Applying ${inc_dir}"
        receive_from_s3 "${LATEST_CHAIN}/${inc_dir}" ""
    done
fi

log "Restore done: ${DEST_ZVOL}"
log "Next steps: mount ${DEST_ZVOL} as ext4 and use PBS or extract data"

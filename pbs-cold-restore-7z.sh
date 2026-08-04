#!/bin/bash
set -euo pipefail

# pbs-cold-restore-7z.sh — pbs-cold-backup-7z.sh 的配套恢复端
#
# 从 S3 逐卷读取 7z 包并还原加密备份流

# ======= 配置区(均可用同名环境变量覆盖) =======
S3_BUCKET="${S3_BUCKET:-baidu-pbs}"
S3_PREFIX="${S3_PREFIX:-pbs-cold-backup-7z}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.openlist.example.com}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-/etc/pbs-cold-backup/passphrase}"

# 7z 封装层口令，备份端和恢复端须保持一致
WEAK_PASS="${WEAK_PASS:-canon2024}"

DEST_ZVOL="${DEST_ZVOL:-tank/pbs-restore}"
DEST_SIZE="${DEST_SIZE:-1T}"
RESTORE_TMP="${RESTORE_TMP:-/tank/pbs-cold-backup-tmp}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-6}"
RETRY_DELAY="${RETRY_DELAY:-5}"
SEVENZ="${SEVENZ:-7zz}"
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

# 链根目录:多源共用同一 S3 前缀时按 SRC_TAG 隔离(独立运行为空,布局不变)
CHAIN_ROOT="${S3_PREFIX}${SRC_TAG:+/${SRC_TAG}}"

# 列出 S3 上的所有全量链根目录
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

# 列出某个目录下的所有"分卷"文件,按卷号数值序
list_volumes() {
    local subpath="$1"

    aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${CHAIN_ROOT}/${subpath}/" \
        --endpoint-url="${S3_ENDPOINT}" \
        --query 'Contents[].Key' \
        --output json |
        jq -r '.[]' |
        awk -F/ '{print $NF}' |
        grep -E '\.7z\.[0-9]+$' |
        awk -F. '{printf "%d\t%s\n", $NF, $0}' |
        sort -n | cut -f2
}

# 下载单个"分卷"到指定文件
download_volume() {
    local subpath="$1"
    local part="$2"
    local dest="$3"

    aws s3api get-object \
        --bucket "${S3_BUCKET}" \
        --key "${CHAIN_ROOT}/${subpath}/${part}" \
        --endpoint-url="${S3_ENDPOINT}" \
        "$dest" \
        >/dev/null
}

# 从 S3 逐卷读取 7z 包并还原加密备份流
stream_volumes() {
    local subpath="$1"
    local volumes="$2"
    local dest="$3"

    local part
    for part in $volumes; do
        log "Processing ${subpath}/${part}"
        if ! retry download_volume "${subpath}" "${part}" "$dest"; then
            log "ERROR: failed downloading ${subpath}/${part}"
            return 1
        fi
        # 分卷条目参数与容量校验
        "$SEVENZ" x -so -p"${WEAK_PASS}" "$dest"
        rm -f "$dest"
    done
}

# 从 S3 逐卷拉流、解密、解压并 zfs receive
receive_from_s3() {
    local subpath="$1"
    local receive_flags="${2:-}"

    local volumes
    volumes=$(list_volumes "$subpath")
    if [ -z "$volumes" ]; then
        log "ERROR: no volumes found in ${subpath}"
        return 1
    fi

    local dest
    dest=$(mktemp "${RESTORE_TMP}/volume.XXXXXX.7z")

    stream_volumes "$subpath" "$volumes" "$dest" | \
        gpg --ignore-mdc-error --decrypt \
            --passphrase-file "${PASSPHRASE_FILE}" --batch --yes | \
        zstd -d | \
        zfs receive ${receive_flags} "${DEST_ZVOL}"

    rm -f "$dest"
}

# ======= 预检 =======
for cmd in "$SEVENZ" zstd gpg aws jq zfs; do
    command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: 找不到命令: $cmd"; exit 1; }
done
[ -r "$PASSPHRASE_FILE" ] || { log "ERROR: 口令文件不可读: $PASSPHRASE_FILE"; exit 1; }
mkdir -p "$RESTORE_TMP"

cleanup_tmp() { rm -f "${RESTORE_TMP}"/volume.*.7z 2>/dev/null || true; }
trap cleanup_tmp EXIT

# ======= 找最新含 full/ 的链 =======
ALL_CHAINS=$(list_s3_chains)
if [ -z "$ALL_CHAINS" ]; then
    log "ERROR: no backup chains found in S3"
    exit 1
fi

LATEST_CHAIN=""
for chain in $ALL_CHAINS; do
    if [ -n "$(list_volumes "${chain}/full" 2>/dev/null)" ]; then
        LATEST_CHAIN="$chain"
    fi
done

if [ -z "$LATEST_CHAIN" ]; then
    log "ERROR: no full backup found in any S3 chain"
    exit 1
fi

log "Latest full backup chain: ${LATEST_CHAIN}"

# ======= 创建目标 zvol =======
if ! zfs list "${DEST_ZVOL}" >/dev/null 2>&1; then
    log "Creating destination zvol ${DEST_ZVOL} (${DEST_SIZE})"
    zfs create -V "${DEST_SIZE}" "${DEST_ZVOL}"
fi

# ======= 接收全量 =======
log "Restoring full backup from chain ${LATEST_CHAIN}"
receive_from_s3 "${LATEST_CHAIN}/full" "-F"

# ======= 按序应用增量 =======
INCREMENTAL_DIRS=$(aws s3api list-objects-v2 \
    --bucket "${S3_BUCKET}" \
    --prefix "${CHAIN_ROOT}/${LATEST_CHAIN}/" \
    --delimiter "/" \
    --endpoint-url="${S3_ENDPOINT}" \
    --query 'CommonPrefixes[].Prefix' \
    --output json |
    jq -r '.[]' |
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

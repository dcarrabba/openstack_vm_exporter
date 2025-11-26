#!/bin/bash

set -e

############################################
# Helper functions
############################################

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        PKG_MGR=""
    fi
}

install_pkg() {
    local pkg="$1"

    if [[ -z "$PKG_MGR" ]]; then
        echo "[!] No supported package manager found (apt/dnf/yum not available)."
        echo "    Please install the package manually: $pkg"
        return 1
    fi

    echo "[*] Trying to install package '$pkg' using $PKG_MGR..."

    case "$PKG_MGR" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
            ;;
        dnf)
            dnf install -y "$pkg"
            ;;
        yum)
            yum install -y "$pkg"
            ;;
    esac
}

ensure_cmd() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_rhel="${3:-$2}"   # if not specified, same as Debian pkg

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo "[!] Command '$cmd' not found."

    local pkg=""
    case "$PKG_MGR" in
        apt) pkg="$pkg_apt" ;;
        dnf|yum) pkg="$pkg_rhel" ;;
        *) pkg="$pkg_apt" ;;
    esac

    if [[ -n "$pkg" ]]; then
        install_pkg "$pkg" || {
            echo "[!] Failed to install '$pkg'."
            return 1
        }
    else
        echo "[!] No package mapped to '$cmd'."
        return 1
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[!] After installation, '$cmd' is still not available. Exiting."
        return 1
    fi
}

check_dependencies() {
    detect_pkg_manager

    # Base dependencies
    ensure_cmd jq jq jq
    ensure_cmd pv pv pv
    ensure_cmd openstack python3-openstackclient python3-openstackclient

    # Cinder is used only as a fallback, so it will be installed later in Phase 3 if needed.
    # qemu-img is only required if conversion is requested (checked later).
}

############################################
# Interactive input
############################################

echo "============================================="
echo " OpenStack VM Export"
echo "============================================="

# VM Name
read -rp "OpenStack VM name: " VM_NAME
if [[ -z "$VM_NAME" ]]; then
    echo "[!] VM name not specified. Exiting."
    exit 1
fi

# Base export path
read -rp "Base export path (default: /root/imgstore): " BASE_DIR
if [[ -z "$BASE_DIR" ]]; then
    BASE_DIR="/root/imgstore"
fi

# Normalize trailing slash
BASE_DIR="${BASE_DIR%/}"
EXPORT_DIR="${BASE_DIR}/${VM_NAME}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="${EXPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/${VM_NAME}_${TIMESTAMP}.log"

mkdir -p "$EXPORT_DIR"
mkdir -p "$LOG_DIR"

############################################
# Conversion options
############################################

CONVERT_IMAGES="no"
TARGET_FORMAT=""
TARGET_EXT=""
QEMU_OUT_FORMAT=""

read -rp "Do you want to convert QCOW2 images after download? [y/N]: " CONVERT_CHOICE

case "$CONVERT_CHOICE" in
    y|Y)
        CONVERT_IMAGES="yes"
        echo
        echo "Select target format:"
        echo "  1) Hyper-V (VHDX)"
        echo "  2) VMware (VMDK)"
        read -rp "Choice [1-2]: " FORMAT_CHOICE

        case "$FORMAT_CHOICE" in
            1)
                TARGET_FORMAT="hyperv"
                TARGET_EXT="vhdx"
                QEMU_OUT_FORMAT="vhdx"
                ;;
            2)
                TARGET_FORMAT="vmware"
                TARGET_EXT="vmdk"
                QEMU_OUT_FORMAT="vmdk"
                ;;
            *)
                echo "[!] Invalid choice. No conversion will be performed."
                CONVERT_IMAGES="no"
                ;;
        esac
        ;;
    *)
        CONVERT_IMAGES="no"
        ;;
esac

# Check base dependencies (jq, pv, openstack)
check_dependencies

# If conversion requested, ensure qemu-img is available
if [[ "$CONVERT_IMAGES" == "yes" ]]; then
    # On Ubuntu qemu-img is in qemu-utils, on RHEL in qemu-img
    ensure_cmd qemu-img qemu-utils qemu-img || {
        echo "[!] You requested conversion but 'qemu-img' is not available."
        exit 1
    }
    echo "[+] Conversion enabled: $TARGET_FORMAT (.$TARGET_EXT)"
else
    echo "[+] Conversion disabled: only QCOW2 images will be downloaded."
fi

echo "[+] VM Name: $VM_NAME"
echo "[+] Export directory: $EXPORT_DIR"
echo "[+] Log file: $LOG_FILE"
echo

# From now on, log everything to file + stdout
exec > >(tee -a "$LOG_FILE") 2>&1

VOLUME_IDS=$(openstack server show "$VM_NAME" -f value -c volumes_attached | grep -oE "[0-9a-f-]{36}")
declare -A VOLUME_NAMES SNAP_IDS SNAP_VOL_IDS IMG_IDS

############################################
# Phase 1: Create snapshots for all volumes
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME=$(openstack volume show "$VOLUME_ID" -f value -c name)
    VOLUME_NAMES[$VOLUME_ID]="$VOLUME_NAME"
    SNAP_NAME="snap-${VOLUME_NAME}"

    EXISTING_SNAP_ID=$(openstack volume snapshot list --volume "$VOLUME_ID" -f json | jq -r '.[] | select(.Name=="'"$SNAP_NAME"'") | .ID')
    if [[ -n "$EXISTING_SNAP_ID" ]]; then
        STATUS=$(openstack volume snapshot show "$EXISTING_SNAP_ID" -f value -c status)
        if [[ "$STATUS" == "available" ]]; then
            echo "[✔] Snapshot $SNAP_NAME already exists and is available: $EXISTING_SNAP_ID"
            SNAP_IDS[$VOLUME_ID]="$EXISTING_SNAP_ID"
            continue
        fi
    fi

    echo "[*] Creating snapshot for $VOLUME_NAME (ID: $VOLUME_ID)"
    SNAP_ID=$(openstack volume snapshot create --force --volume "$VOLUME_ID" "$SNAP_NAME" -f value -c id)
    SNAP_IDS[$VOLUME_ID]="$SNAP_ID"

    echo "    [+] Waiting for snapshot to become 'available'..."
    while true; do
        STATUS=$(openstack volume snapshot show "$SNAP_ID" -f value -c status)
        echo "        [...] Snapshot status: $STATUS"
        [[ "$STATUS" == "available" ]] && break
        [[ "$STATUS" == "error" ]] && { echo "    [!] Snapshot error. Aborting."; exit 1; }
        sleep 5
    done
done

############################################
# Phase 2: Create cloned volumes from snapshots (same type)
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    SNAP_ID="${SNAP_IDS[$VOLUME_ID]}"
    CLONE_VOL_NAME="clone-${VOLUME_NAME}"

    EXISTING_VOL_ID=$(openstack volume list -f json | jq -r '.[] | select(.Name=="'"$CLONE_VOL_NAME"'") | .ID')
    if [[ -n "$EXISTING_VOL_ID" ]]; then
        STATUS=$(openstack volume show "$EXISTING_VOL_ID" -f value -c status)
        if [[ "$STATUS" == "available" ]] ; then
            echo "[✔] Clone volume $CLONE_VOL_NAME already exists and is available: $EXISTING_VOL_ID"
            SNAP_VOL_IDS[$VOLUME_ID]="$EXISTING_VOL_ID"
            continue
        fi
    fi

    VOL_TYPE=$(openstack volume show "$VOLUME_ID" -f value -c type)
    echo "[*] Creating clone volume from snapshot for $VOLUME_NAME (type: $VOL_TYPE)"

    SNAP_VOL_ID=$(openstack volume create \
        --snapshot "$SNAP_ID" \
        --type "$VOL_TYPE" \
        "$CLONE_VOL_NAME" -f value -c id)

    SNAP_VOL_IDS[$VOLUME_ID]="$SNAP_VOL_ID"

    echo "    [+] Safety wait: 20 seconds..."
    sleep 20
done

############################################
# Phase 3: Create Glance images (openstack -> fallback to cinder)
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    IMG_NAME="img-${VOLUME_NAME}"
    SNAP_VOL_ID="${SNAP_VOL_IDS[$VOLUME_ID]}"

    EXISTING_IMG_ID=$(openstack image list -f json | jq -r '.[] | select(.Name=="'"$IMG_NAME"'") | .ID')
    if [[ -n "$EXISTING_IMG_ID" ]]; then
        echo "[✔] Image $IMG_NAME already exists: $EXISTING_IMG_ID"
        STATUS=$(openstack image show "$EXISTING_IMG_ID" -f value -c status)
        SIZE=$(openstack image show "$EXISTING_IMG_ID" -f value -c size)
        if [[ "$STATUS" == "active" && "$SIZE" -gt 0 ]]; then
            IMG_IDS[$VOLUME_ID]="$EXISTING_IMG_ID"
            continue
        fi
    fi

    echo "[*] Creating image $IMG_NAME from volume $SNAP_VOL_ID"

    # Attempt 1: standard openstack image create --volume
    if openstack image create --volume "$SNAP_VOL_ID" \
        --container-format bare \
        --disk-format qcow2 \
        "$IMG_NAME"; then
        echo "    [+] Image created using 'openstack image create'."
    else
        echo "    [!] 'openstack image create' failed, trying fallback with 'cinder upload-to-image'..."

        # Ensure cinder client is available for fallback
        ensure_cmd cinder python3-cinderclient python3-cinderclient || {
            echo "    [!] 'cinder' client not available. Cannot use fallback method."
            exit 1
        }

        if ! cinder upload-to-image \
            --force \
            --disk-format qcow2 \
            --container-format bare \
            "$SNAP_VOL_ID" \
            "$IMG_NAME"; then
            echo "    [!] Error during 'cinder upload-to-image' for $IMG_NAME"
            exit 1
        fi

        echo "    [+] Image created using 'cinder upload-to-image'."
    fi

    echo "    [+] Waiting for image to appear in Glance..."
    while true; do
        IMG_ID=$(openstack image list -f json | jq -r '.[] | select(.Name=="'"$IMG_NAME"'") | .ID')
        if [[ -n "$IMG_ID" ]]; then
            echo "    [+] Glance image detected: $IMG_ID"
            IMG_IDS[$VOLUME_ID]="$IMG_ID"
            break
        fi
        echo "        [...] Waiting for image '$IMG_NAME' to be registered..."
        sleep 5
    done

    echo "    [+] Waiting for image to become 'active'..."
    while true; do
        STATUS=$(openstack image show "$IMG_ID" -f value -c status 2>/dev/null || echo "missing")
        SIZE=$(openstack image show "$IMG_ID" -f value -c size 2>/dev/null || echo "0")

        echo "        [...] Status: $STATUS - Size: $SIZE"

        if [[ "$STATUS" == "active" && "$SIZE" -gt 0 ]]; then
            break
        elif [[ "$STATUS" == "error" || "$STATUS" == "deleted" ]]; then
            echo "    [!] Image $IMG_ID is in error/deleted state. Aborting."
            exit 1
        elif [[ "$STATUS" == "missing" ]]; then
            echo "        [...] Image not visible yet. Waiting..."
        fi
        sleep 5
    done
done

############################################
# Phase 4: Download and (optional) conversion
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    IMG_ID="${IMG_IDS[$VOLUME_ID]}"
    QCOW_FILE="${EXPORT_DIR}/img-${VOLUME_NAME}.qcow2"

    echo "[*] Downloading image $IMG_ID into $QCOW_FILE"
    IMG_SIZE=$(openstack image show "$IMG_ID" -f value -c size)

    # Use openstack image save (modern and does not require glance client)
    openstack image save "$IMG_ID" --file - | pv -W -s "$IMG_SIZE" > "$QCOW_FILE"

    if [[ "$CONVERT_IMAGES" == "yes" ]]; then
        TARGET_FILE="${EXPORT_DIR}/img-${VOLUME_NAME}.${TARGET_EXT}"

        if [[ -f "$TARGET_FILE" ]]; then
            echo "[✔] Converted file $TARGET_FILE already exists. Skipping conversion."
        else
            echo "[*] Converting $QCOW_FILE -> $TARGET_FILE ($TARGET_FORMAT)"
            qemu-img convert -f qcow2 -O "$QEMU_OUT_FORMAT" "$QCOW_FILE" "$TARGET_FILE"
            echo "[+] Conversion completed: $TARGET_FILE"
        fi
    fi
done

echo "[✔] Export completed for VM: $VM_NAME"
if [[ "$CONVERT_IMAGES" == "yes" ]]; then
    echo "[✔] Images converted to $TARGET_FORMAT (.$TARGET_EXT)"
else
    echo "[i] Only QCOW2 files have been generated."
fi

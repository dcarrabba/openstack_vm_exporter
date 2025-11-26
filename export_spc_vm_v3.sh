#!/bin/bash

set -e

############################################
# Funzioni di supporto
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
        echo "[!] Nessun package manager supportato (apt/dnf/yum non trovati)."
        echo "    Installa manualmente il pacchetto: $pkg"
        return 1
    fi

    echo "[*] Provo a installare il pacchetto '$pkg' con $PKG_MGR..."

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
    local pkg_rhel="${3:-$2}"   # se non specificato, stesso nome pkg

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    echo "[!] Comando '$cmd' non trovato."

    local pkg=""
    case "$PKG_MGR" in
        apt) pkg="$pkg_apt" ;;
        dnf|yum) pkg="$pkg_rhel" ;;
        *) pkg="$pkg_apt" ;;
    esac

    if [[ -n "$pkg" ]]; then
        install_pkg "$pkg" || {
            echo "[!] Impossibile installare '$pkg'."
            return 1
        }
    else
        echo "[!] Nessun pacchetto associato a '$cmd'."
        return 1
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[!] Dopo l'installazione, '$cmd' non è ancora disponibile. Esco."
        return 1
    fi
}

check_dependencies() {
    detect_pkg_manager

    # Dipendenze base
    ensure_cmd jq jq jq
    ensure_cmd pv pv pv
    ensure_cmd openstack python3-openstackclient python3-openstackclient

    # Cinder sarà usato solo come fallback, quindi lo installiamo solo se serve, dentro la Fase 3.
    # qemu-img solo se conversione richiesta (controllo più avanti)
}

############################################
# Ingresso script: input interattivo
############################################

echo "============================================="
echo " Export VM da OpenStack"
echo "============================================="

# Nome VM
read -rp "Nome della VM su OpenStack: " VM_NAME
if [[ -z "$VM_NAME" ]]; then
    echo "[!] Nome VM non specificato. Esco."
    exit 1
fi

# Percorso base salvataggio
read -rp "Percorso base di salvataggio (default: /root/imgstore): " BASE_DIR
if [[ -z "$BASE_DIR" ]]; then
    BASE_DIR="/root/imgstore"
fi

# Normalizziamo per evitare doppio slash
BASE_DIR="${BASE_DIR%/}"
EXPORT_DIR="${BASE_DIR}/${VM_NAME}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="${EXPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/${VM_NAME}_${TIMESTAMP}.log"

mkdir -p "$EXPORT_DIR"
mkdir -p "$LOG_DIR"

############################################
# Scelta conversione iniziale
############################################

CONVERT_IMAGES="no"
TARGET_FORMAT=""
TARGET_EXT=""
QEMU_OUT_FORMAT=""

read -rp "Vuoi convertire le immagini QCOW2 dopo il download? [y/N]: " CONVERT_CHOICE

case "$CONVERT_CHOICE" in
    y|Y|s|S)
        CONVERT_IMAGES="yes"
        echo
        echo "Seleziona il formato di destinazione:"
        echo "  1) Hyper-V (VHDX)"
        echo "  2) VMware (VMDK)"
        read -rp "Scelta [1-2]: " FORMAT_CHOICE

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
                echo "[!] Scelta non valida. Nessuna conversione verrà eseguita."
                CONVERT_IMAGES="no"
                ;;
        esac
        ;;
    *)
        CONVERT_IMAGES="no"
        ;;
esac

# Controllo dipendenze base (jq, pv, openstack)
check_dependencies

# Se è richiesta la conversione, assicuriamoci di avere qemu-img
if [[ "$CONVERT_IMAGES" == "yes" ]]; then
    # su Ubuntu qemu-img sta in qemu-utils, su RHEL in qemu-img
    ensure_cmd qemu-img qemu-utils qemu-img || {
        echo "[!] Hai richiesto la conversione ma 'qemu-img' non è disponibile."
        exit 1
    }
    echo "[+] Conversione abilitata: formato $TARGET_FORMAT (.$TARGET_EXT)"
else
    echo "[+] Conversione disabilitata: verranno scaricati solo i QCOW2."
fi

echo "[+] Nome VM: $VM_NAME"
echo "[+] Directory export: $EXPORT_DIR"
echo "[+] Log file: $LOG_FILE"
echo

# Da qui in poi logghiamo tutto su file + stdout
exec > >(tee -a "$LOG_FILE") 2>&1

VOLUME_IDS=$(openstack server show "$VM_NAME" -f value -c volumes_attached | grep -oE "[0-9a-f-]{36}")
declare -A VOLUME_NAMES SNAP_IDS SNAP_VOL_IDS IMG_IDS

############################################
# Fase 1: Crea snapshot per tutti i volumi
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME=$(openstack volume show "$VOLUME_ID" -f value -c name)
    VOLUME_NAMES[$VOLUME_ID]="$VOLUME_NAME"
    SNAP_NAME="snap-${VOLUME_NAME}"

    EXISTING_SNAP_ID=$(openstack volume snapshot list --volume "$VOLUME_ID" -f json | jq -r '.[] | select(.Name=="'"$SNAP_NAME"'") | .ID')
    if [[ -n "$EXISTING_SNAP_ID" ]]; then
        STATUS=$(openstack volume snapshot show "$EXISTING_SNAP_ID" -f value -c status)
        if [[ "$STATUS" == "available" ]]; then
            echo "[✔] Snapshot $SNAP_NAME già esistente e pronto: $EXISTING_SNAP_ID"
            SNAP_IDS[$VOLUME_ID]="$EXISTING_SNAP_ID"
            continue
        fi
    fi

    echo "[*] Snapshot per $VOLUME_NAME (ID: $VOLUME_ID)"
    SNAP_ID=$(openstack volume snapshot create --force --volume "$VOLUME_ID" "$SNAP_NAME" -f value -c id)
    SNAP_IDS[$VOLUME_ID]="$SNAP_ID"

    echo "    [+] Attesa snapshot 'available'..."
    while true; do
        STATUS=$(openstack volume snapshot show "$SNAP_ID" -f value -c status)
        echo "        [...] Stato snapshot: $STATUS"
        [[ "$STATUS" == "available" ]] && break
        [[ "$STATUS" == "error" ]] && { echo "    [!] Errore snapshot"; exit 1; }
        sleep 5
    done
done

############################################
# Fase 2: Crea volumi da snapshot (stesso tipo)
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    SNAP_ID="${SNAP_IDS[$VOLUME_ID]}"
    CLONE_VOL_NAME="clone-${VOLUME_NAME}"

    EXISTING_VOL_ID=$(openstack volume list -f json | jq -r '.[] | select(.Name=="'"$CLONE_VOL_NAME"'") | .ID')
    if [[ -n "$EXISTING_VOL_ID" ]]; then
        STATUS=$(openstack volume show "$EXISTING_VOL_ID" -f value -c status)
        if [[ "$STATUS" == "available" ]] ; then
            echo "[✔] Volume $CLONE_VOL_NAME già esistente e pronto: $EXISTING_VOL_ID"
            SNAP_VOL_IDS[$VOLUME_ID]="$EXISTING_VOL_ID"
            continue
        fi
    fi

    VOL_TYPE=$(openstack volume show "$VOLUME_ID" -f value -c type)
    echo "[*] Volume da snapshot per $VOLUME_NAME (type: $VOL_TYPE)"

    SNAP_VOL_ID=$(openstack volume create \
        --snapshot "$SNAP_ID" \
        --type "$VOL_TYPE" \
        "$CLONE_VOL_NAME" -f value -c id)

    SNAP_VOL_IDS[$VOLUME_ID]="$SNAP_VOL_ID"

    echo "    [+] Attesa 20s di sicurezza..."
    sleep 20
done

############################################
# Fase 3: Crea immagini Glance (openstack -> fallback cinder)
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    IMG_NAME="img-${VOLUME_NAME}"
    SNAP_VOL_ID="${SNAP_VOL_IDS[$VOLUME_ID]}"

    EXISTING_IMG_ID=$(openstack image list -f json | jq -r '.[] | select(.Name=="'"$IMG_NAME"'") | .ID')
    if [[ -n "$EXISTING_IMG_ID" ]]; then
        echo "[✔] Immagine $IMG_NAME già esistente: $EXISTING_IMG_ID"
        STATUS=$(openstack image show "$EXISTING_IMG_ID" -f value -c status)
        SIZE=$(openstack image show "$EXISTING_IMG_ID" -f value -c size)
        if [[ "$STATUS" == "active" && "$SIZE" -gt 0 ]]; then
            IMG_IDS[$VOLUME_ID]="$EXISTING_IMG_ID"
            continue
        fi
    fi

    echo "[*] Creazione immagine $IMG_NAME da volume $SNAP_VOL_ID"

    # Tentativo 1: metodo standard openstack image create --volume
    if openstack image create --volume "$SNAP_VOL_ID" \
        --container-format bare \
        --disk-format qcow2 \
        "$IMG_NAME"; then
        echo "    [+] Immagine creata con 'openstack image create'."
    else
        echo "    [!] 'openstack image create' fallita, provo fallback con 'cinder upload-to-image'..."

        # Assicuriamoci di avere cinder client
        ensure_cmd cinder python3-cinderclient python3-cinderclient || {
            echo "    [!] 'cinder' non disponibile. Impossibile usare il metodo di fallback."
            exit 1
        }

        if ! cinder upload-to-image \
            --force \
            --disk-format qcow2 \
            --container-format bare \
            "$SNAP_VOL_ID" \
            "$IMG_NAME"; then
            echo "    [!] Errore durante 'cinder upload-to-image' per $IMG_NAME"
            exit 1
        fi

        echo "    [+] Immagine creata con 'cinder upload-to-image'."
    fi

    echo "    [+] Attesa registrazione immagine..."
    while true; do
        IMG_ID=$(openstack image list -f json | jq -r '.[] | select(.Name=="'"$IMG_NAME"'") | .ID')
        if [[ -n "$IMG_ID" ]]; then
            echo "    [+] Immagine Glance rilevata: $IMG_ID"
            IMG_IDS[$VOLUME_ID]="$IMG_ID"
            break
        fi
        echo "        [...] Attesa registrazione immagine '$IMG_NAME'..."
        sleep 5
    done

    echo "    [+] Attesa disponibilità immagine..."
    while true; do
        STATUS=$(openstack image show "$IMG_ID" -f value -c status 2>/dev/null || echo "missing")
        SIZE=$(openstack image show "$IMG_ID" -f value -c size 2>/dev/null || echo "0")

        echo "        [...] Stato: $STATUS - Size: $SIZE"

        if [[ "$STATUS" == "active" && "$SIZE" -gt 0 ]]; then
            break
        elif [[ "$STATUS" == "error" || "$STATUS" == "deleted" ]]; then
            echo "    [!] Errore immagine $IMG_ID (status: $STATUS). Interrompo."
            exit 1
        elif [[ "$STATUS" == "missing" ]]; then
            echo "        [...] Immagine ancora non visibile. Attendo..."
        fi
        sleep 5
    done
done

############################################
# Fase 4: Download e (opzionale) conversione
############################################
for VOLUME_ID in $VOLUME_IDS; do
    VOLUME_NAME="${VOLUME_NAMES[$VOLUME_ID]}"
    IMG_ID="${IMG_IDS[$VOLUME_ID]}"
    QCOW_FILE="${EXPORT_DIR}/img-${VOLUME_NAME}.qcow2"

    echo "[*] Download immagine $IMG_ID in $QCOW_FILE"
    IMG_SIZE=$(openstack image show "$IMG_ID" -f value -c size)

    # Uso openstack image save (più moderno e non richiede glance client)
    openstack image save "$IMG_ID" --file - | pv -W -s "$IMG_SIZE" > "$QCOW_FILE"

    if [[ "$CONVERT_IMAGES" == "yes" ]]; then
        TARGET_FILE="${EXPORT_DIR}/img-${VOLUME_NAME}.${TARGET_EXT}"

        if [[ -f "$TARGET_FILE" ]]; then
            echo "[✔] File convertito $TARGET_FILE già esistente. Salto conversione."
        else
            echo "[*] Conversione $QCOW_FILE -> $TARGET_FILE ($TARGET_FORMAT)"
            qemu-img convert -f qcow2 -O "$QEMU_OUT_FORMAT" "$QCOW_FILE" "$TARGET_FILE"
            echo "[+] Conversione completata: $TARGET_FILE"
        fi
    fi
done

echo "[✔] Esportazione completata per VM: $VM_NAME"
if [[ "$CONVERT_IMAGES" == "yes" ]]; then
    echo "[✔] Immagini convertite in formato $TARGET_FORMAT (.$TARGET_EXT)"
else
    echo "[i] Sono stati generati solo i file QCOW2."
fi

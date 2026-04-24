#!/usr/bin/env bash
# Deploys Cisco Intersight Virtual Appliance on OpenStack using the OpenStack CLI.
# No Terraform required.
#
# Requirements:
#   pip install python-openstackclient openstacksdk requests
#
# Usage:
#   source setup_env.sh ~/.config/openstack/clouds.yaml openstack
#   IMAGE_FILE=/path/to/intersight.tar bash deploy.sh [appliance.conf]

set -euo pipefail

CONFIG="${1:-appliance.conf}"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: Config file '${CONFIG}' not found."
  echo "Copy appliance.conf.example to appliance.conf and edit it."
  exit 1
fi

source "${CONFIG}"

# Required config keys
for var in VM_HOSTNAME ADMIN_PASSWORD MANAGEMENT_NETWORK FLAVOR IMAGE_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in ${CONFIG}"
    exit 1
  fi
done

# Defaults
VM_AZ="${VM_AZ:-nova}"
VOLUME_AZ="${VOLUME_AZ:-nova}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-intersight-sg}"
FLOATING_IP_POOL="${FLOATING_IP_POOL:-}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8,8.8.4.4}"
NTP_SERVERS="${NTP_SERVERS:-pool.ntp.org}"
PROXY_HOST="${PROXY_HOST:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_USERNAME="${PROXY_USERNAME:-}"
PROXY_PASSWORD="${PROXY_PASSWORD:-}"

DOWNLOAD_DIR="${TMPDIR:-/tmp}/intersight-download"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# Unset all proxy vars — OpenStack endpoints are internal and must not go through proxy
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

if [[ -z "${OS_AUTH_URL:-}" ]]; then
  echo "ERROR: OpenStack environment not set. Run: source setup_env.sh first."
  exit 1
fi

for cmd in python3 openstack; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required. Install with: pip install python-openstackclient"
    exit 1
  fi
done

mkdir -p "${DOWNLOAD_DIR}"

# ---------------------------------------------------------------------------
# Step 0 — Remove existing instance only (volumes are preserved)
# ---------------------------------------------------------------------------

echo "=== Step 0: Checking for existing resources ==="

SERVER_ID=$(openstack server show "${VM_HOSTNAME}" -f value -c id 2>/dev/null || true)

if [[ -n "${SERVER_ID}" ]]; then
  echo ""
  echo "  Existing instance found: ${VM_HOSTNAME} (${SERVER_ID})"
  echo ""
  read -r -p "  Delete this instance and proceed with deployment? [y/N]: " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  echo "  Stopping instance ..."
  openstack server stop "${SERVER_ID}" 2>/dev/null || true
  for attempt in $(seq 1 24); do
    STATUS=$(openstack server show "${SERVER_ID}" -f value -c status 2>/dev/null || echo "gone")
    [[ "${STATUS}" == "SHUTOFF" || "${STATUS}" == "gone" ]] && break
    sleep 5
  done

  echo "  Detaching volumes ..."
  while IFS= read -r vol_id; do
    [[ -z "${vol_id}" ]] && continue
    echo "    Detaching ${vol_id} ..."
    openstack server remove volume "${SERVER_ID}" "${vol_id}" 2>/dev/null || true
  done < <(openstack server volume list "${SERVER_ID}" -f value -c ID 2>/dev/null || true)

  echo "  Deleting instance ..."
  openstack server delete "${SERVER_ID}" 2>/dev/null || true
  for attempt in $(seq 1 24); do
    STATUS=$(openstack server show "${SERVER_ID}" -f value -c status 2>/dev/null || echo "gone")
    [[ "${STATUS}" == "gone" ]] && break
    sleep 5
  done
  echo "  Instance deleted. Volumes are preserved."
else
  echo "  No existing instance found."
fi

echo ""

# ---------------------------------------------------------------------------
# Step 1 — Resolve disk image files into DISK_FILES array
# ---------------------------------------------------------------------------

if [[ -n "${IMAGE_FILE:-}" ]]; then
  echo "=== Step 1: Using local image file ==="

  if [[ ! -f "${IMAGE_FILE}" ]]; then
    echo "ERROR: IMAGE_FILE '${IMAGE_FILE}' not found."
    exit 1
  fi

  if [[ "${IMAGE_FILE}" == *.tar || "${IMAGE_FILE}" == *.tar.gz || "${IMAGE_FILE}" == *.tgz ]]; then
    echo "Extracting tar archive ..."
    tar -xf "${IMAGE_FILE}" -C "${DOWNLOAD_DIR}"

    DISK_FILES=()
    while IFS= read -r f; do DISK_FILES+=("$f"); done < <(find "${DOWNLOAD_DIR}" \( -name "*.qcow2" -o -name "*.qcow" \) | sort -V)
    if [[ ${#DISK_FILES[@]} -eq 0 ]]; then
      while IFS= read -r f; do DISK_FILES+=("$f"); done < <(find "${DOWNLOAD_DIR}" \( -name "*.vmdk" -o -name "*.ova" \) | sort -V)
    fi
    if [[ ${#DISK_FILES[@]} -eq 0 ]]; then
      echo "ERROR: No qcow2, qcow, vmdk, or ova found inside ${IMAGE_FILE}"
      exit 1
    fi
  else
    DISK_FILES=("${IMAGE_FILE}")
  fi

  echo "Found ${#DISK_FILES[@]} disk image(s):"
  for f in "${DISK_FILES[@]}"; do echo "  $(basename "${f}")"; done

else
  # ---- Cisco download mode ----
  for var in CISCO_CLIENT_ID CISCO_CLIENT_SECRET; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: ${var} is not set."
      echo ""
      echo "Either set IMAGE_FILE to a local tar image:"
      echo "  export IMAGE_FILE=/path/to/intersight.tar"
      echo ""
      echo "Or set Cisco API credentials to download automatically:"
      echo "  export CISCO_CLIENT_ID=your-client-id"
      echo "  export CISCO_CLIENT_SECRET=your-client-secret"
      exit 1
    fi
  done

  CISCO_API_TOKEN_URL="https://id.cisco.com/oauth2/default/v1/token"
  CISCO_SOFTWARE_API="https://apix.cisco.com/software/v4.0"
  INTERSIGHT_MDF_ID="286320499"

  echo "=== Step 1: Authenticating with Cisco Software Central ==="
  CISCO_TOKEN=$(python3 - <<PYEOF
import sys, requests
resp = requests.post("${CISCO_API_TOKEN_URL}",
    data={"grant_type": "client_credentials",
          "client_id": "${CISCO_CLIENT_ID}",
          "client_secret": "${CISCO_CLIENT_SECRET}"}, timeout=30)
if resp.status_code != 200:
    print(f"ERROR: {resp.status_code} {resp.text}", file=sys.stderr); sys.exit(1)
print(resp.json()["access_token"])
PYEOF
)
  echo "Authentication successful."

  echo ""
  echo "=== Step 2: Querying latest Intersight VA release ==="
  read LATEST_VERSION DOWNLOAD_URL FILENAME < <(python3 - <<PYEOF
import sys, requests
headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}
resp = requests.get("${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases", headers=headers, timeout=30)
if resp.status_code != 200:
    print(f"ERROR: {resp.status_code}", file=sys.stderr); sys.exit(1)
releases = resp.json().get("releases", [])
if not releases:
    print("ERROR: No releases found", file=sys.stderr); sys.exit(1)
version = releases[0].get("releaseVersion", "unknown")
resp = requests.get(f"${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases/{version}/files", headers=headers, timeout=30)
files = resp.json().get("files", [])
target = next((f for f in files if f["fileName"].endswith(".qcow2")), None) or \
         next((f for f in files if f["fileName"].endswith(".ova")), None)
if not target:
    print("ERROR: No image found", file=sys.stderr); sys.exit(1)
print(version, target["downloadURL"], target["fileName"])
PYEOF
)
  echo "Latest version: ${LATEST_VERSION} — ${FILENAME}"

  LOCAL_FILE="${DOWNLOAD_DIR}/${FILENAME}"
  echo ""
  echo "=== Step 4: Downloading ${FILENAME} ==="
  python3 - <<PYEOF
import sys, requests
headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}
with requests.get("${DOWNLOAD_URL}", headers=headers, stream=True, timeout=300) as r:
    r.raise_for_status()
    total = int(r.headers.get("content-length", 0))
    done = 0
    with open("${LOCAL_FILE}", "wb") as f:
        for chunk in r.iter_content(chunk_size=8*1024*1024):
            f.write(chunk); done += len(chunk)
            if total:
                print(f"  {done*100//total}% ({done//1024//1024}/{total//1024//1024} MB)", end="\r")
print("\nDone.")
PYEOF

  if [[ "${FILENAME}" == *.ova ]]; then
    QCOW2="${DOWNLOAD_DIR}/intersight.qcow2"
    qemu-img convert -f vmdk -O qcow2 "${LOCAL_FILE}" "${QCOW2}"
    LOCAL_FILE="${QCOW2}"
  fi

  DISK_FILES=("${LOCAL_FILE}")
fi

# ---------------------------------------------------------------------------
# Step 3 — Upload missing disk images to Glance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Checking disk images in Glance ==="

DISK_SIZES=()
MISSING_INDICES=()

for i in "${!DISK_FILES[@]}"; do
  DISK_NUM=$((i + 1))
  DISK_NAME="${IMAGE_NAME}-${DISK_NUM}"

  # Use image list so multiple images with the same name don't cause
  # 'image show' to fail with an ambiguity error and falsely trigger re-upload
  ACTIVE_COUNT=$(openstack image list --name "${DISK_NAME}" -f value -c Status 2>/dev/null \
                 | grep -c "^active$" || true)

  if [[ "${ACTIVE_COUNT}" -gt 0 ]]; then
    echo "  ${DISK_NAME}: active — skipping"
  else
    echo "  ${DISK_NAME}: not found — will upload"
    MISSING_INDICES+=("${i}")
  fi
done

# ---------------------------------------------------------------------------
# Step 4 — Upload missing disks
# ---------------------------------------------------------------------------

if [[ ${#MISSING_INDICES[@]} -gt 0 ]]; then
  echo ""
  echo "=== Step 4: Uploading ${#MISSING_INDICES[@]} disk image(s) ==="

  for i in "${MISSING_INDICES[@]}"; do
    DISK_FILE="${DISK_FILES[$i]}"
    DISK_NUM=$((i + 1))
    DISK_NAME="${IMAGE_NAME}-${DISK_NUM}"

    if [[ "${DISK_FILE}" == *.vmdk ]]; then
      QCOW2="${DOWNLOAD_DIR}/disk-${DISK_NUM}.qcow2"
      echo "  Converting $(basename "${DISK_FILE}") ..."
      qemu-img convert -f vmdk -O qcow2 "${DISK_FILE}" "${QCOW2}"
      DISK_FILE="${QCOW2}"
    fi

    case "${DISK_FILE}" in
      *.qcow2|*.qcow) DISK_FORMAT="qcow2" ;;
      *.raw)          DISK_FORMAT="raw"   ;;
      *)              DISK_FORMAT="qcow2" ;;
    esac

    echo ""
    echo "  Uploading disk ${DISK_NUM}/${#DISK_FILES[@]}: ${DISK_NAME}"
    openstack image create "${DISK_NAME}" \
      --file "${DISK_FILE}" \
      --disk-format "${DISK_FORMAT}" \
      --container-format bare \
      --private \
      --protected \
      --progress
  done

  [[ -z "${IMAGE_FILE:-}" ]] && rm -rf "${DOWNLOAD_DIR}"
else
  echo "  All disk images already in Glance."
fi

# Ensure all disk images are marked protected (covers already-uploaded images)
echo "  Protecting images from deletion ..."
for i in $(seq 1 "${#DISK_FILES[@]}"); do
  IMG_NAME="${IMAGE_NAME}-${i}"
  IMG_ID=$(openstack image list --name "${IMG_NAME}" --status active \
           -f value -c ID 2>/dev/null | head -1 || true)
  if [[ -n "${IMG_ID}" ]]; then
    openstack image set --protected "${IMG_ID}" 2>/dev/null || true
    echo "    ${IMG_NAME}: protected"
  fi
done

# ---------------------------------------------------------------------------
# Step 5 — Read virtual sizes from Glance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5: Reading virtual disk sizes from Glance ==="

DISK_COUNT="${#DISK_FILES[@]}"
DISK_SIZES=()

for i in $(seq 0 $((DISK_COUNT - 1))); do
  DISK_NUM=$((i + 1))
  IMG_NAME="${IMAGE_NAME}-${DISK_NUM}"

  # Get virtual_size in bytes from Glance, pick first active image
  IMG_ID=$(openstack image list --name "${IMG_NAME}" --status active \
           -f value -c ID 2>/dev/null | head -1 || true)

  SIZE_GB=500
  if [[ -n "${IMG_ID}" ]]; then
    SIZE_BYTES=$(openstack image show "${IMG_ID}" -f value -c virtual_size 2>/dev/null || echo "")
    if [[ -n "${SIZE_BYTES}" && "${SIZE_BYTES}" =~ ^[0-9]+$ && "${SIZE_BYTES}" -gt 0 ]]; then
      # Ceiling division: (bytes + GiB - 1) / GiB
      SIZE_GB=$(( (SIZE_BYTES + 1073741823) / 1073741824 ))
    fi
  fi

  DISK_SIZES+=("${SIZE_GB}")
  echo "  ${IMG_NAME}: ${SIZE_GB} GB"
done

if [[ "${#DISK_SIZES[@]}" -ne "${DISK_COUNT}" ]]; then
  echo "ERROR: Could not resolve sizes for all ${DISK_COUNT} disk images."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 6 — Create security group
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 6: Configuring security group ==="

if ! openstack security group show "${SECURITY_GROUP_NAME}" &>/dev/null; then
  echo "  Creating security group: ${SECURITY_GROUP_NAME}"
  openstack security group create "${SECURITY_GROUP_NAME}" \
    --description "Intersight Virtual Appliance"

  openstack security group rule create "${SECURITY_GROUP_NAME}" --protocol tcp --dst-port 443 --ingress
  openstack security group rule create "${SECURITY_GROUP_NAME}" --protocol tcp --dst-port 80  --ingress
  openstack security group rule create "${SECURITY_GROUP_NAME}" --protocol tcp --dst-port 22  --ingress
  openstack security group rule create "${SECURITY_GROUP_NAME}" --protocol tcp --dst-port 1 --dst-port 65535 --egress
else
  echo "  Security group '${SECURITY_GROUP_NAME}' already exists — skipping"
fi

# ---------------------------------------------------------------------------
# Step 7 — Resolve volumes (reuse existing or create from images)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 7: Resolving volumes ==="

VOLUME_IDS=()
VOLUMES_NEED_CREATION=false

for i in "${!DISK_SIZES[@]}"; do
  DISK_NUM=$((i + 1))
  VOL_NAME="${VM_HOSTNAME}-disk-${DISK_NUM}"

  # Check if a volume with this name already exists and is available
  EXISTING_VOL=$(openstack volume list --name "${VOL_NAME}" -f value -c ID -c Status 2>/dev/null \
                 | awk '$2 == "available" {print $1}' | head -1 || true)

  if [[ -n "${EXISTING_VOL}" ]]; then
    echo "  ${VOL_NAME}: reusing existing volume ${EXISTING_VOL}"
    VOLUME_IDS+=("${EXISTING_VOL}")
  else
    echo "  ${VOL_NAME}: not found — will create from image"
    VOLUME_IDS+=("")
    VOLUMES_NEED_CREATION=true
  fi
done

# Create any missing volumes from Glance images
if [[ "${VOLUMES_NEED_CREATION}" == "true" ]]; then
  echo ""
  echo "  Creating missing volumes from Glance images ..."
  for i in "${!VOLUME_IDS[@]}"; do
    [[ -n "${VOLUME_IDS[$i]}" ]] && continue

    DISK_NUM=$((i + 1))
    VOL_NAME="${VM_HOSTNAME}-disk-${DISK_NUM}"
    IMG_NAME="${IMAGE_NAME}-${DISK_NUM}"
    SIZE="${DISK_SIZES[$i]}"

    IMG_ID=$(openstack image list --name "${IMG_NAME}" --status active -f value -c ID 2>/dev/null \
             | head -1 || true)
    if [[ -z "${IMG_ID}" ]]; then
      echo "ERROR: No active Glance image '${IMG_NAME}' found."
      exit 1
    fi

    echo "  Creating ${VOL_NAME} (${SIZE} GB) from ${IMG_NAME} (${IMG_ID}) ..."
    VOL_ID=$(openstack volume create "${VOL_NAME}" \
      --image "${IMG_ID}" \
      --size "${SIZE}" \
      --availability-zone "${VOLUME_AZ}" \
      -f value -c id)

    if [[ -z "${VOL_ID}" ]]; then
      echo "ERROR: Failed to create volume ${VOL_NAME}."
      exit 1
    fi
    VOLUME_IDS[$i]="${VOL_ID}"
    echo "    ${VOL_NAME}: ${VOL_ID}"
  done

  echo "  Waiting for volumes to become available ..."
  for i in "${!VOLUME_IDS[@]}"; do
    VOL_ID="${VOLUME_IDS[$i]}"
    VOL_NAME="${VM_HOSTNAME}-disk-$((i + 1))"
    for attempt in $(seq 1 60); do
      STATUS=$(openstack volume show "${VOL_ID}" -f value -c status 2>/dev/null || echo "unknown")
      case "${STATUS}" in
        available) echo "    ${VOL_NAME}: available"; break ;;
        error*)
          echo "ERROR: Volume ${VOL_NAME} (${VOL_ID}) is in error status."
          openstack volume show "${VOL_ID}" -c status -c volume_type 2>/dev/null || true
          exit 1
          ;;
        *) printf "\r    ${VOL_NAME}: ${STATUS} (%d/60) ..." "${attempt}"; sleep 10 ;;
      esac
    done
  done
fi

# ---------------------------------------------------------------------------
# Step 8 — Generate user data
# ---------------------------------------------------------------------------

DNS_JSON=$(python3 -c "
import json, sys
servers = '${DNS_SERVERS}'.split(',')
print(json.dumps([s.strip() for s in servers]))
")

NTP_JSON=$(python3 -c "
import json
servers = '${NTP_SERVERS}'.split(',')
print(json.dumps([s.strip() for s in servers]))
")

PROXY_BLOCK=""
if [[ -n "${PROXY_HOST}" ]]; then
  PROXY_BLOCK=",\"proxy\":{\"host\":\"${PROXY_HOST}\",\"port\":${PROXY_PORT}"
  if [[ -n "${PROXY_USERNAME}" ]]; then
    PROXY_BLOCK+=",\"username\":\"${PROXY_USERNAME}\",\"password\":\"${PROXY_PASSWORD}\""
  fi
  PROXY_BLOCK+="}"
fi

USER_DATA=$(cat <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
write_files:
  - path: /etc/intersight/appliance-config.json
    permissions: '0600'
    content: |
      {
        "hostname": "${VM_HOSTNAME}",
        "dns": ${DNS_JSON},
        "ntp": ${NTP_JSON},
        "adminPassword": "${ADMIN_PASSWORD}"${PROXY_BLOCK}
      }
runcmd:
  - hostnamectl set-hostname ${VM_HOSTNAME}
  - [ sh, -c, "if [ -f /usr/local/bin/intersight-appliance-setup ]; then /usr/local/bin/intersight-appliance-setup --config /etc/intersight/appliance-config.json; fi" ]
EOF
)

USERDATA_FILE="${DOWNLOAD_DIR}/user-data.yaml"
echo "${USER_DATA}" > "${USERDATA_FILE}"

# ---------------------------------------------------------------------------
# Step 9 — Boot instance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 9: Booting instance ==="

# Attach pre-created volumes by ID — no image-to-volume conversion at boot time
BDM_ARGS=()
for i in "${!VOLUME_IDS[@]}"; do
  BOOT_INDEX=$([[ $i -eq 0 ]] && echo "0" || echo "-1")
  BDM_ARGS+=(--block-device "source_type=volume,uuid=${VOLUME_IDS[$i]},boot_index=${BOOT_INDEX},disk_bus=scsi,device_type=disk,delete_on_termination=false")
done

SERVER_ID=$(openstack server create "${VM_HOSTNAME}" \
  --flavor "${FLAVOR}" \
  --network "${MANAGEMENT_NETWORK}" \
  --security-group "${SECURITY_GROUP_NAME}" \
  --availability-zone "${VM_AZ}" \
  --user-data "${USERDATA_FILE}" \
  "${BDM_ARGS[@]}" \
  -f value -c id)

echo "  Instance created: ${SERVER_ID}"
echo "  Waiting for instance to become active ..."
for attempt in $(seq 1 60); do
  STATUS=$(openstack server show "${SERVER_ID}" -f value -c status 2>/dev/null || echo "unknown")
  case "${STATUS}" in
    ACTIVE)   echo "  Instance is active."; break ;;
    ERROR)    echo "ERROR: Instance entered ERROR status."; openstack server show "${SERVER_ID}" -c status -c fault 2>/dev/null; exit 1 ;;
    *)        printf "\r  Status: ${STATUS} (%d/60) ..." "${attempt}"; sleep 10 ;;
  esac
done

MGMT_IP=$(openstack server show "${SERVER_ID}" -f value -c addresses | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "  Management IP: ${MGMT_IP}"

# ---------------------------------------------------------------------------
# Step 10 — Assign floating IP (optional)
# ---------------------------------------------------------------------------

if [[ -n "${FLOATING_IP_POOL}" ]]; then
  echo ""
  echo "=== Step 10: Assigning floating IP ==="
  FLOATING_IP=$(openstack floating ip create "${FLOATING_IP_POOL}" -f value -c floating_ip_address)
  openstack server add floating ip "${SERVER_ID}" "${FLOATING_IP}"
  echo "  Floating IP: ${FLOATING_IP}"
  ACCESS_IP="${FLOATING_IP}"
else
  ACCESS_IP="${MGMT_IP}"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "================================================"
echo " Intersight Virtual Appliance deployed"
echo "================================================"
echo "  Instance:  ${VM_HOSTNAME} (${SERVER_ID})"
echo "  Access:    https://${ACCESS_IP}"
echo "  Username:  admin"
echo "  Password:  (set in ${CONFIG})"
echo ""
echo "  Allow 10-15 minutes for the appliance to initialise."
echo "================================================"

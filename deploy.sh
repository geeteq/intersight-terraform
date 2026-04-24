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
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-nova}"
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
# Step 0 — Remove any existing instance and volumes (images are preserved)
# ---------------------------------------------------------------------------

echo "=== Step 0: Cleaning up existing instance and volumes ==="

EXISTING_SERVER=$(openstack server show "${VM_HOSTNAME}" -f value -c id 2>/dev/null || true)
if [[ -n "${EXISTING_SERVER}" ]]; then
  echo "  Deleting instance: ${VM_HOSTNAME}"
  openstack server delete "${VM_HOSTNAME}" --wait
else
  echo "  No existing instance found"
fi

# Delete volumes named {VM_HOSTNAME}-disk-*
while IFS= read -r vol_id; do
  [[ -z "${vol_id}" ]] && continue
  vol_name=$(openstack volume show "${vol_id}" -f value -c name 2>/dev/null || true)
  echo "  Deleting volume: ${vol_name} (${vol_id})"
  openstack volume delete "${vol_id}" 2>/dev/null || true
done < <(openstack volume list --name "${VM_HOSTNAME}-disk-%" -f value -c ID 2>/dev/null || true)

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

  EXISTS=$(python3 - <<PYEOF
import openstack
conn = openstack.connect(load_envvars=True, insecure=True)
image = conn.image.find_image("${DISK_NAME}", ignore_missing=True)
if image and image.status == "active" and (image.size or 0) > 100 * 1024 * 1024:
    print("yes")
else:
    if image:
        print(f"  Deleting invalid image '${DISK_NAME}' ...", flush=True)
        conn.image.delete_image(image.id)
    print("no")
PYEOF
)

  if [[ "${EXISTS}" == "yes" ]]; then
    echo "  ${DISK_NAME}: exists — skipping"
  else
    echo "  ${DISK_NAME}: will upload"
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
      --progress
  done

  [[ -z "${IMAGE_FILE:-}" ]] && rm -rf "${DOWNLOAD_DIR}"
else
  echo "  All disk images already in Glance."
fi

# ---------------------------------------------------------------------------
# Step 5 — Read virtual sizes from Glance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5: Reading virtual disk sizes from Glance ==="

DISK_COUNT="${#DISK_FILES[@]}"

readarray -t DISK_SIZES < <(python3 - <<PYEOF
import openstack, math
conn = openstack.connect(load_envvars=True, insecure=True)
for i in range(1, ${DISK_COUNT} + 1):
    image = conn.image.find_image("${IMAGE_NAME}-{}".format(i), ignore_missing=True)
    if image and image.virtual_size:
        print(math.ceil(image.virtual_size / 1024**3))
    else:
        print(500)
PYEOF
)

for i in "${!DISK_SIZES[@]}"; do
  echo "  ${IMAGE_NAME}-$((i+1)): ${DISK_SIZES[$i]} GB"
done

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
# Step 7 — Create Cinder volumes from images
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 7: Creating volumes ==="

VOLUME_IDS=()
for i in "${!DISK_SIZES[@]}"; do
  DISK_NUM=$((i + 1))
  VOL_NAME="${VM_HOSTNAME}-disk-${DISK_NUM}"
  SIZE="${DISK_SIZES[$i]}"

  echo "  Creating ${VOL_NAME} (${SIZE} GB) from ${IMAGE_NAME}-${DISK_NUM} ..."
  VOL_ID=$(openstack volume create "${VOL_NAME}" \
    --image "${IMAGE_NAME}-${DISK_NUM}" \
    --size "${SIZE}" \
    --availability-zone "${AVAILABILITY_ZONE}" \
    -f value -c id)
  VOLUME_IDS+=("${VOL_ID}")
  echo "  ${VOL_NAME}: ${VOL_ID}"
done

echo "  Waiting for volumes to become available ..."
for VOL_ID in "${VOLUME_IDS[@]}"; do
  openstack volume wait --available "${VOL_ID}"
done
echo "  All volumes ready."

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

# Build block device mapping: first volume is boot, rest are data
BOOT_DISK="${VOLUME_IDS[0]}"
BDM_ARGS=()
for i in "${!VOLUME_IDS[@]}"; do
  if [[ $i -eq 0 ]]; then
    BDM_ARGS+=(--volume "${VOLUME_IDS[$i]}")
  else
    BDM_ARGS+=(--block-device-mapping "sd$(printf "\\x$(printf '%02x' $((98 + i)))")=${VOLUME_IDS[$i]}:::false")
  fi
done

SERVER_ID=$(openstack server create "${VM_HOSTNAME}" \
  --flavor "${FLAVOR}" \
  --network "${MANAGEMENT_NETWORK}" \
  --security-group "${SECURITY_GROUP_NAME}" \
  --availability-zone "${AVAILABILITY_ZONE}" \
  --user-data "${USERDATA_FILE}" \
  "${BDM_ARGS[@]}" \
  -f value -c id)

echo "  Instance created: ${SERVER_ID}"
echo "  Waiting for instance to become active ..."
openstack server wait --active "${SERVER_ID}" --timeout 300

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

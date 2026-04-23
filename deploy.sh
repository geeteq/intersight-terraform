#!/usr/bin/env bash
# Uploads Cisco Intersight Virtual Appliance disk images to OpenStack and
# runs terraform apply.
#
# The Intersight VA ships as a tar containing multiple qcow2 disk images.
# Each disk is uploaded as {IMAGE_NAME}-1, {IMAGE_NAME}-2, etc.
#
# Two modes:
#   1. Local file:  set IMAGE_FILE=/path/to/intersight.tar (skips Cisco download)
#   2. Auto-download: set CISCO_CLIENT_ID and CISCO_CLIENT_SECRET
#
# Requirements:
#   pip install openstacksdk requests python-openstackclient
#
# Usage:
#   source setup_env.sh ~/.config/openstack/clouds.yaml openstack
#   IMAGE_FILE=/path/to/intersight.tar bash deploy.sh
#   bash deploy.sh   # downloads from Cisco Software Central

set -euo pipefail

TFVARS="${1:-terraform.tfvars}"
DOWNLOAD_DIR="${TMPDIR:-/tmp}/intersight-download"

# Read image_name from tfvars so it matches what Terraform expects.
# Override by setting IMAGE_NAME in the environment.
if [[ -z "${IMAGE_NAME:-}" ]]; then
  IMAGE_NAME=$(grep -E '^\s*image_name\s*=' "${TFVARS}" 2>/dev/null | cut -d'"' -f2 || true)
  IMAGE_NAME="${IMAGE_NAME:-intersight-appliance}"
fi

CISCO_API_TOKEN_URL="https://id.cisco.com/oauth2/default/v1/token"
CISCO_SOFTWARE_API="https://apix.cisco.com/software/v4.0"
INTERSIGHT_MDF_ID="286320499"

# Unset all proxy vars — OpenStack endpoints are internal and must not go through proxy
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

if [[ -z "${OS_AUTH_URL:-}" ]]; then
  echo "ERROR: OpenStack environment not set. Run: source setup_env.sh first."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required"
  exit 1
fi

if ! command -v openstack &>/dev/null; then
  echo "ERROR: 'openstack' CLI is required for image upload."
  echo "Install with: pip install python-openstackclient"
  exit 1
fi

mkdir -p "${DOWNLOAD_DIR}"

# ---------------------------------------------------------------------------
# Step 0 — Clean slate: destroy existing resources and images
# ---------------------------------------------------------------------------

echo "=== Step 0: Cleaning up existing resources ==="

# Destroy Terraform-managed resources if any exist in state
STATE_RESOURCES=$(terraform state list 2>/dev/null || true)
if [[ -n "${STATE_RESOURCES}" ]]; then
  echo "  Destroying existing Terraform resources ..."
  DESTROY_ARGS=(-var-file="${TFVARS}" -auto-approve)
  if [[ ! -f "disk_sizes.auto.tfvars" ]]; then
    DESTROY_ARGS+=(-var 'disk_sizes=[]')
  fi
  terraform destroy "${DESTROY_ARGS[@]}" || true
else
  echo "  No Terraform state found — skipping destroy"
fi

# Remove stale auto-generated tfvars so sizes are recomputed from fresh images
rm -f disk_sizes.auto.tfvars

# Delete all Glance images matching {IMAGE_NAME}-*
echo "  Removing Glance images '${IMAGE_NAME}-*' ..."
python3 - <<PYEOF
import openstack
conn = openstack.connect(load_envvars=True, insecure=True)
images = [i for i in conn.image.images(visibility="private")
          if i.name and i.name.startswith("${IMAGE_NAME}-")]
if not images:
    print("  No matching images found")
for image in images:
    print(f"  Deleting: {image.name} ({image.id})")
    conn.image.delete_image(image.id)
PYEOF

echo ""

# ---------------------------------------------------------------------------
# Step 1 — Resolve disk image files into DISK_FILES array
# ---------------------------------------------------------------------------

if [[ -n "${IMAGE_FILE:-}" ]]; then
  # ---- Local file mode ----
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
      echo ""
      echo "Register for API access at: https://apiconsole.cisco.com"
      exit 1
    fi
  done

  echo "=== Step 1: Authenticating with Cisco Software Central ==="

  CISCO_TOKEN=$(python3 - <<PYEOF
import sys, requests

resp = requests.post(
    "${CISCO_API_TOKEN_URL}",
    data={
        "grant_type": "client_credentials",
        "client_id": "${CISCO_CLIENT_ID}",
        "client_secret": "${CISCO_CLIENT_SECRET}",
    },
    timeout=30,
)
if resp.status_code != 200:
    print(f"ERROR: Cisco auth failed: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)
print(resp.json()["access_token"])
PYEOF
)
  echo "Authentication successful."

  echo ""
  echo "=== Step 2: Querying latest Intersight Virtual Appliance release ==="

  read LATEST_VERSION DOWNLOAD_URL FILENAME < <(python3 - <<PYEOF
import sys, requests

headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}

resp = requests.get("${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases", headers=headers, timeout=30)
if resp.status_code != 200:
    print(f"ERROR: Failed to fetch releases: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)

releases = resp.json().get("releases", [])
if not releases:
    print("ERROR: No releases found for Intersight VA", file=sys.stderr)
    sys.exit(1)

version = releases[0].get("releaseVersion", "unknown")

resp = requests.get(f"${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases/{version}/files", headers=headers, timeout=30)
if resp.status_code != 200:
    print(f"ERROR: Failed to fetch files: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)

files = resp.json().get("files", [])
qcow2 = next((f for f in files if f["fileName"].endswith(".qcow2")), None)
ova   = next((f for f in files if f["fileName"].endswith(".ova")), None)
target = qcow2 or ova
if not target:
    print("ERROR: No qcow2 or OVA found for this release", file=sys.stderr)
    sys.exit(1)

print(version, target["downloadURL"], target["fileName"])
PYEOF
)
  echo "Latest version: ${LATEST_VERSION}"
  echo "File:           ${FILENAME}"

  echo ""
  echo "=== Step 4: Downloading Intersight VA ${LATEST_VERSION} ==="

  LOCAL_FILE="${DOWNLOAD_DIR}/${FILENAME}"

  python3 - <<PYEOF
import sys, requests

headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}
print(f"Downloading: ${LOCAL_FILE}")

with requests.get("${DOWNLOAD_URL}", headers=headers, stream=True, timeout=300) as r:
    r.raise_for_status()
    total = int(r.headers.get("content-length", 0))
    downloaded = 0
    with open("${LOCAL_FILE}", "wb") as f:
        for chunk in r.iter_content(chunk_size=8 * 1024 * 1024):
            f.write(chunk)
            downloaded += len(chunk)
            if total:
                pct = downloaded * 100 // total
                print(f"  {pct}% ({downloaded // 1024 // 1024} MB / {total // 1024 // 1024} MB)", end="\r")
print(f"\nDownload complete.")
PYEOF

  if [[ "${FILENAME}" == *.ova ]]; then
    echo "Converting OVA to qcow2 ..."
    if ! command -v qemu-img &>/dev/null; then
      echo "ERROR: qemu-img not found. Install with: brew install qemu"
      exit 1
    fi
    QCOW2_FILE="${DOWNLOAD_DIR}/intersight-appliance.qcow2"
    qemu-img convert -f vmdk -O qcow2 "${LOCAL_FILE}" "${QCOW2_FILE}"
    LOCAL_FILE="${QCOW2_FILE}"
    echo "Conversion complete."
  fi

  DISK_FILES=("${LOCAL_FILE}")
fi

# ---------------------------------------------------------------------------
# Step 3 — Check which disk images are missing in OpenStack
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Checking disk images in OpenStack ==="

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
        print(f"  Deleting invalid image '${DISK_NAME}' (status={image.status}, size={image.size}) ...", flush=True)
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
# Step 5 — Upload missing disk images
# ---------------------------------------------------------------------------

if [[ ${#MISSING_INDICES[@]} -gt 0 ]]; then
  echo ""
  echo "=== Step 5: Uploading ${#MISSING_INDICES[@]} disk image(s) to OpenStack ==="

  for i in "${MISSING_INDICES[@]}"; do
    DISK_FILE="${DISK_FILES[$i]}"
    DISK_NUM=$((i + 1))
    DISK_NAME="${IMAGE_NAME}-${DISK_NUM}"

    # Convert vmdk to qcow2 if needed
    if [[ "${DISK_FILE}" == *.vmdk ]]; then
      if ! command -v qemu-img &>/dev/null; then
        echo "ERROR: qemu-img not found. Install with: brew install qemu"
        exit 1
      fi
      QCOW2_FILE="${DOWNLOAD_DIR}/disk-${DISK_NUM}.qcow2"
      echo "  Converting $(basename "${DISK_FILE}") to qcow2 ..."
      qemu-img convert -f vmdk -O qcow2 "${DISK_FILE}" "${QCOW2_FILE}"
      DISK_FILE="${QCOW2_FILE}"
    fi

    case "${DISK_FILE}" in
      *.qcow2) DISK_FORMAT="qcow2" ;;
      *.qcow)  DISK_FORMAT="qcow2" ;;
      *.raw)   DISK_FORMAT="raw"   ;;
      *)       DISK_FORMAT="qcow2" ;;
    esac

    echo ""
    echo "  Uploading disk ${DISK_NUM}/${#DISK_FILES[@]}: ${DISK_NAME}"
    echo "  Source: $(basename "${DISK_FILE}")"

    openstack image create "${DISK_NAME}" \
      --file "${DISK_FILE}" \
      --disk-format "${DISK_FORMAT}" \
      --container-format bare \
      --private \
      --progress
  done

  if [[ -z "${IMAGE_FILE:-}" ]]; then
    echo "Cleaning up temporary files ..."
    rm -rf "${DOWNLOAD_DIR}"
  fi
else
  echo "All disk images already exist in OpenStack — skipping upload."
fi

# ---------------------------------------------------------------------------
# Step 5.5 — Write disk_sizes.auto.tfvars from Glance virtual sizes
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5.5: Reading virtual disk sizes from Glance ==="

DISK_COUNT="${#DISK_FILES[@]}"

python3 - <<PYEOF
import openstack, math

conn = openstack.connect(load_envvars=True, insecure=True)

sizes = []
for i in range(1, ${DISK_COUNT} + 1):
    name = "${IMAGE_NAME}-{}".format(i)
    image = conn.image.find_image(name, ignore_missing=True)
    if image and image.virtual_size:
        size_gb = math.ceil(image.virtual_size / (1024 ** 3))
        sizes.append(size_gb)
        print(f"  {name}: {size_gb} GB (virtual size)")
    else:
        sizes.append(500)
        print(f"  {name}: virtual_size not available — defaulting to 500 GB")

tfvars_line = "disk_sizes = [{}]".format(", ".join(str(s) for s in sizes))

with open("disk_sizes.auto.tfvars", "w") as f:
    f.write("# Auto-generated by deploy.sh from Glance virtual sizes — do not edit manually\n")
    f.write(tfvars_line + "\n")

print(f"\nWritten disk_sizes.auto.tfvars")
print(f"  {tfvars_line}")
PYEOF

# ---------------------------------------------------------------------------
# Step 6 — Run Terraform
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 6: Running terraform apply ==="
echo ""

terraform apply -var-file="${TFVARS}"

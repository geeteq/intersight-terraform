#!/usr/bin/env bash
# Uploads a Cisco Intersight Virtual Appliance image to OpenStack and runs
# terraform apply.
#
# Two modes:
#   1. Local file:  set IMAGE_FILE=/path/to/intersight.tar (skips Cisco download)
#   2. Auto-download: set CISCO_CLIENT_ID and CISCO_CLIENT_SECRET
#
# Requirements:
#   pip install openstacksdk requests
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

# Intersight Virtual Appliance MDF ID on Cisco Software Central
INTERSIGHT_MDF_ID="286320499"

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

# ---------------------------------------------------------------------------
# Step 1 — Resolve local image file or download from Cisco
# ---------------------------------------------------------------------------

mkdir -p "${DOWNLOAD_DIR}"

if [[ -n "${IMAGE_FILE:-}" ]]; then
  # ---- Local file mode ----
  echo "=== Step 1: Using local image file ==="

  if [[ ! -f "${IMAGE_FILE}" ]]; then
    echo "ERROR: IMAGE_FILE '${IMAGE_FILE}' not found."
    exit 1
  fi

  echo "Image file: ${IMAGE_FILE}"
  LOCAL_FILE="${IMAGE_FILE}"

  # Extract tar archives (Cisco packages qcow2/vmdk inside a tar)
  if [[ "${IMAGE_FILE}" == *.tar || "${IMAGE_FILE}" == *.tar.gz || "${IMAGE_FILE}" == *.tgz ]]; then
    echo "Extracting tar archive ..."
    tar -xf "${IMAGE_FILE}" -C "${DOWNLOAD_DIR}"

    # Find qcow2 first, then vmdk, then ova inside the extracted contents
    EXTRACTED=$(find "${DOWNLOAD_DIR}" \( -name "*.qcow2" -o -name "*.vmdk" -o -name "*.ova" \) | head -1)
    if [[ -z "${EXTRACTED}" ]]; then
      echo "ERROR: No qcow2, vmdk, or ova found inside ${IMAGE_FILE}"
      exit 1
    fi
    echo "Found image: ${EXTRACTED}"
    LOCAL_FILE="${EXTRACTED}"
  fi

  SKIP_UPLOAD_CHECK="no"
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
import sys
import requests

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
import sys
import requests

headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}

releases_url = "${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases"
resp = requests.get(releases_url, headers=headers, timeout=30)

if resp.status_code != 200:
    print(f"ERROR: Failed to fetch releases: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)

releases = resp.json().get("releases", [])
if not releases:
    print("ERROR: No releases found for Intersight VA", file=sys.stderr)
    sys.exit(1)

latest = releases[0]
version = latest.get("releaseVersion", "unknown")

files_url = f"${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases/{version}/files"
resp = requests.get(files_url, headers=headers, timeout=30)

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

  SKIP_UPLOAD_CHECK="yes"
fi

# ---------------------------------------------------------------------------
# Step 3 — Check if image already exists in OpenStack
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Checking if image already exists in OpenStack ==="

IMAGE_EXISTS=$(python3 - <<PYEOF
import openstack, os
conn = openstack.connect(load_envvars=True, insecure=True)
image = conn.image.find_image("${IMAGE_NAME}", ignore_missing=True)
print("yes" if image else "no")
PYEOF
)

if [[ "${IMAGE_EXISTS}" == "yes" ]]; then
  echo "Image '${IMAGE_NAME}' already exists in OpenStack — skipping upload."
else
  if [[ "${SKIP_UPLOAD_CHECK}" == "yes" ]]; then
    # -------------------------------------------------------------------------
    # Step 4 — Download the image (Cisco mode only)
    # -------------------------------------------------------------------------

    echo ""
    echo "=== Step 4: Downloading Intersight VA ${LATEST_VERSION} ==="

    LOCAL_FILE="${DOWNLOAD_DIR}/${FILENAME}"

    python3 - <<PYEOF
import sys
import requests

headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}
url = "${DOWNLOAD_URL}"

print(f"Downloading from: {url}")
print(f"Destination:      ${LOCAL_FILE}")

with requests.get(url, headers=headers, stream=True, timeout=300) as r:
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

print(f"\nDownload complete: ${LOCAL_FILE}")
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
      echo "Conversion complete: ${LOCAL_FILE}"
    fi
  fi

  # Convert vmdk to qcow2 if the extracted/provided file is a vmdk
  if [[ "${LOCAL_FILE}" == *.vmdk ]]; then
    echo "Converting vmdk to qcow2 ..."
    if ! command -v qemu-img &>/dev/null; then
      echo "ERROR: qemu-img not found. Install with: brew install qemu"
      exit 1
    fi
    QCOW2_FILE="${DOWNLOAD_DIR}/intersight-appliance.qcow2"
    qemu-img convert -f vmdk -O qcow2 "${LOCAL_FILE}" "${QCOW2_FILE}"
    LOCAL_FILE="${QCOW2_FILE}"
    echo "Conversion complete: ${LOCAL_FILE}"
  fi

  # -------------------------------------------------------------------------
  # Step 5 — Upload image to OpenStack
  # -------------------------------------------------------------------------

  echo ""
  echo "=== Step 5: Uploading image to OpenStack ==="

  # Determine disk format from file extension
  case "${LOCAL_FILE}" in
    *.qcow2) DISK_FORMAT="qcow2" ;;
    *.raw)   DISK_FORMAT="raw" ;;
    *)       DISK_FORMAT="qcow2" ;;
  esac

  python3 - <<PYEOF
import openstack, os, sys

conn = openstack.connect(load_envvars=True, insecure=True)

print(f"Uploading '${IMAGE_NAME}' to OpenStack ...")
print(f"Source: ${LOCAL_FILE}")

image = conn.image.create_image(
    name="${IMAGE_NAME}",
    disk_format="${DISK_FORMAT}",
    container_format="bare",
    visibility="private",
    filename="${LOCAL_FILE}",
)

image = conn.image.get_image(image.id)
print(f"Upload complete.")
print(f"  ID:     {image.id}")
print(f"  Name:   {image.name}")
print(f"  Size:   {image.size // 1024 // 1024} MB")
print(f"  Status: {image.status}")
PYEOF

  if [[ -z "${IMAGE_FILE:-}" ]]; then
    echo "Cleaning up temporary files ..."
    rm -rf "${DOWNLOAD_DIR}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6 — Run Terraform
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 6: Running terraform apply ==="
echo ""

terraform apply -var-file="${TFVARS}"

#!/usr/bin/env bash
# Downloads the latest Cisco Intersight Virtual Appliance image from Cisco
# Software Central and uploads it to OpenStack, then runs terraform apply.
#
# Requirements:
#   pip install openstacksdk requests
#
# Usage:
#   source setup_env.sh ~/.config/openstack/clouds.yaml openstack
#   bash deploy.sh

set -euo pipefail

TFVARS="${1:-terraform.tfvars}"
IMAGE_NAME="intersight-appliance"
DOWNLOAD_DIR="${TMPDIR:-/tmp}/intersight-download"
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

for var in CISCO_CLIENT_ID CISCO_CLIENT_SECRET; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set."
    echo "Set these in your environment or .env file:"
    echo "  export CISCO_CLIENT_ID=your-client-id"
    echo "  export CISCO_CLIENT_SECRET=your-client-secret"
    echo ""
    echo "Register for API access at: https://apiconsole.cisco.com"
    exit 1
  fi
done

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required"
  exit 1
fi

mkdir -p "${DOWNLOAD_DIR}"

# ---------------------------------------------------------------------------
# Step 1 — Authenticate with Cisco Software Central
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Step 2 — Find the latest Intersight VA qcow2 release
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Querying latest Intersight Virtual Appliance release ==="

read LATEST_VERSION DOWNLOAD_URL FILENAME < <(python3 - <<PYEOF
import sys
import requests

headers = {"Authorization": f"Bearer ${CISCO_TOKEN}"}

# Get latest releases for Intersight VA
releases_url = "${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases"
resp = requests.get(releases_url, headers=headers, timeout=30)

if resp.status_code != 200:
    print(f"ERROR: Failed to fetch releases: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)

releases = resp.json().get("releases", [])
if not releases:
    print("ERROR: No releases found for Intersight VA", file=sys.stderr)
    sys.exit(1)

# Pick the latest release
latest = releases[0]
version = latest.get("releaseVersion", "unknown")

# Get download files for this release
files_url = f"${CISCO_SOFTWARE_API}/metadata/${INTERSIGHT_MDF_ID}/releases/{version}/files"
resp = requests.get(files_url, headers=headers, timeout=30)

if resp.status_code != 200:
    print(f"ERROR: Failed to fetch files: {resp.status_code} {resp.text}", file=sys.stderr)
    sys.exit(1)

files = resp.json().get("files", [])

# Prefer qcow2, fallback to ova
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

# ---------------------------------------------------------------------------
# Step 3 — Check if image already exists in OpenStack
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Checking if image already exists in OpenStack ==="

IMAGE_EXISTS=$(python3 - <<PYEOF
import openstack, os
conn = openstack.connect(auth_url=os.environ["OS_AUTH_URL"], insecure=True)
image = conn.image.find_image("${IMAGE_NAME}", ignore_missing=True)
print("yes" if image else "no")
PYEOF
)

if [[ "${IMAGE_EXISTS}" == "yes" ]]; then
  echo "Image '${IMAGE_NAME}' already exists in OpenStack — skipping download and upload."
else
  # -------------------------------------------------------------------------
  # Step 4 — Download the image
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

  # Convert OVA to qcow2 if needed
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

  # -------------------------------------------------------------------------
  # Step 5 — Upload image to OpenStack
  # -------------------------------------------------------------------------

  echo ""
  echo "=== Step 5: Uploading image to OpenStack ==="

  python3 - <<PYEOF
import openstack, os, sys

conn = openstack.connect(auth_url=os.environ["OS_AUTH_URL"], insecure=True)

print(f"Uploading '${IMAGE_NAME}' to OpenStack ...")
print(f"Source: ${LOCAL_FILE}")

image = conn.image.create_image(
    name="${IMAGE_NAME}",
    disk_format="qcow2",
    container_format="bare",
    visibility="private",
)

with open("${LOCAL_FILE}", "rb") as f:
    conn.image.upload_image(image, data=f)

image = conn.image.get_image(image.id)
print(f"Upload complete.")
print(f"  ID:     {image.id}")
print(f"  Name:   {image.name}")
print(f"  Size:   {image.size // 1024 // 1024} MB")
print(f"  Status: {image.status}")
PYEOF

  echo "Cleaning up temporary files ..."
  rm -rf "${DOWNLOAD_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 6 — Run Terraform
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 6: Running terraform apply ==="
echo ""

terraform apply -var-file="${TFVARS}"

#!/usr/bin/env bash
set -euo pipefail

SITES_DIR="$(dirname "$0")/sites"
STATE_DIR="$(dirname "$0")/.states"

usage() {
  echo "Usage: $0 <command> <site>"
  echo ""
  echo "Commands:"
  echo "  plan     Show what changes would be made"
  echo "  apply    Apply config and enforce desired state"
  echo "  drift    Check for drift (exits 1 if drift detected)"
  echo "  destroy  Destroy all resources for a site"
  echo ""
  echo "Available sites:"
  for f in "$SITES_DIR"/*.tfvars; do
    echo "  $(basename "$f" .tfvars)"
  done
  echo ""
  echo "Examples:"
  echo "  $0 plan site-a"
  echo "  $0 apply site-a"
  echo "  $0 drift site-b"
  exit 1
}

[ $# -lt 2 ] && usage

COMMAND=$1
SITE=$2
TFVARS="$SITES_DIR/${SITE}.tfvars"
STATE_FILE="$STATE_DIR/${SITE}.tfstate"

if [ ! -f "$TFVARS" ]; then
  echo "ERROR: No tfvars file found for site '${SITE}' at ${TFVARS}"
  exit 1
fi

mkdir -p "$STATE_DIR"

echo "==> Site:    $SITE"
echo "==> Vars:    $TFVARS"
echo "==> State:   $STATE_FILE"
echo ""

terraform init -input=false -reconfigure \
  -backend-config="path=${STATE_FILE}" > /dev/null

case "$COMMAND" in
  plan)
    terraform plan \
      -var-file="$TFVARS" \
      -state="$STATE_FILE" \
      -input=false
    ;;

  apply)
    terraform apply \
      -var-file="$TFVARS" \
      -state="$STATE_FILE" \
      -input=false \
      -auto-approve
    ;;

  drift)
    echo "==> Checking for drift on site: $SITE"
    set +e
    terraform plan \
      -var-file="$TFVARS" \
      -state="$STATE_FILE" \
      -detailed-exitcode \
      -input=false
    EXIT=$?
    set -e
    if [ $EXIT -eq 2 ]; then
      echo ""
      echo "DRIFT DETECTED on site: $SITE"
      echo "Run: $0 apply $SITE"
      exit 1
    elif [ $EXIT -eq 1 ]; then
      echo "Terraform plan failed."
      exit 1
    else
      echo "No drift — site $SITE is in sync."
    fi
    ;;

  destroy)
    echo "WARNING: This will destroy all Intersight resources for site: $SITE"
    read -r -p "Type the site name to confirm: " CONFIRM
    if [ "$CONFIRM" != "$SITE" ]; then
      echo "Aborted."
      exit 1
    fi
    terraform destroy \
      -var-file="$TFVARS" \
      -state="$STATE_FILE" \
      -input=false \
      -auto-approve
    ;;

  *)
    echo "ERROR: Unknown command '$COMMAND'"
    usage
    ;;
esac

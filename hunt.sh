#!/usr/bin/env bash
# oci-hunter: grabs Always-Free A1.Flex (2 OCPU / 12 GB) the moment capacity
# exists. Designed for GitHub Actions (public repo, free minutes).
#
# Rules:
#  - if the instance already exists            -> exit 0 (stop hunting)
#  - if Oracle says "out of host capacity"     -> exit 0 (green; try in 5 min)
#  - if the launch actually succeeds           -> flip svc, notify Telegram
# Every FF action stays in the FREE tier: launches only VM.Standard.A1.Flex
# bounded at 2 ocpu / 12 GB, Never tries PAYG shapes or larger configs.

set -uo pipefail

NAME='riya-a1'
SHAPE='VM.Standard.A1.Flex'
OCPU=2
MEM=12
OS_VERSION='24.04'

say() { echo "[hunt $(date -u +%H:%M:%S)] $*"; }
die() { say "FATAL: $*"; exit 1; }

# materialize the API key from the secret
mkdir -p "$HOME/.oci" && chmod 700 "$HOME/.oci"
printf '%s' "$OCI_CLI_KEY_CONTENT" | sed 's/\r$//' > "$HOME/.oci/key.pem"
chmod 600 "$HOME/.oci/key.pem"
export OCI_CLI_KEY_FILE="$HOME/.oci/key.pem"
export OCI_CLI_AUTH='api_key'

OC="$HOME/.local/bin/oci"
[ -x "$OC" ] || OC="$(command -v oci)"
oci() { "$OC" "$@"; }

TENANCY="$OCI_CLI_TENANCY"

# ---------------------------------------------------------------- 1. ailu check
say "checking for existing instance '$NAME'"
INSTANCES=$($OC compute instance list --compartment-id "$TENANCY" --output json 2>/dev/null) \
  || die "cannot list instances (auth problem?)"
FOUND=$(echo "$INSTANCES" | jq -r --arg n "$NAME" '[.data[]? | select(."display-name"==$n and ."lifecycle-state"!="TERMINATED")] | length' 2>/dev/null)
if [ -n "${FOUND:-}" ] && [ "$FOUND" -gt 0 ]; then
  say "instance already exists ($FOUND) - nothing to do"
  exit 0
fi

# ---------------------------------------------------------------- 2. image
say "resolving latest Ubuntu $OS_VERSION arm64 image for $SHAPE"
IMG=$(oci compute image list --compartment-id "$TENANCY" \
  --operating-system 'Canonical Ubuntu' --operating-system-version "$OS_VERSION" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --output json 2>/dev/null | jq -r '.data[0].id' 2>/dev/null)
[ -z "${IMG:-}" ] || [ "$IMG" = "null" ] && die "no Ubuntu $OS_VERSION image for $SHAPE"
say "image $IMG"

# ---------------------------------------------------------------- 3. network (reuse)
VCN=$(oci network vcn list --compartment-id "$TENANCY" --output json 2>/dev/null | jq -r '[.data[]? | select(."display-name"=="riya-net" and ."lifecycle-state"!="TERMINATED")][0].id' 2>/dev/null)
if [ -z "${VCN:-}" ] || [ "$VCN" = "null" ]; then
  say "creating VCN riya-net"
  VCN=$(oci network vcn create --compartment-id "$TENANCY" --display-name 'riya-net' --cidr-block '10.0.0.0/16' --output json 2>/dev/null | jq -r '.data.id')
  sleep 10
fi

SUBNET=$(oci network subnet list --compartment-id "$TENANCY" --vcn-id "$VCN" --output json 2>/dev/null | jq -r '[.data[]? | select(."lifecycle-state"=="AVAILABLE")][0].id' 2>/dev/null)
if [ -z "${SUBNET:-}" ] || [ "$SUBNET" = "null" ]; then
  say "creating subnet public"
  SUBNET=$(oci network subnet create --compartment-id "$TENANCY" --vcn-id "$VCN" \
    --display-name 'public' --cidr-block '10.0.1.0/24' --output json 2>/dev/null | jq -r '.data.id')
  sleep 10
fi

IGW=$(oci network internet-gateway list --compartment-id "$TENANCY" --vcn-id "$VCN" --output json 2>/dev/null | jq -r '[.data[]? | select(."lifecycle-state"=="AVAILABLE")][0].id' 2>/dev/null)
if [ -z "${IGW:-}" ] || [ "$IGW" = "null" ]; then
  say "creating internet gateway"
  IGW=$(oci network internet-gateway create --compartment-id "$TENANCY" --vcn-id "$VCN" \
    --display-name 'igw' --is-enabled true --output json 2>/dev/null | jq -r '.data.id')
fi

# route 0.0.0.0/0 via IGW + allow SSH 22 only if the subnet defaults lack them
RT=$(oci network subnet get --subnet-id "$SUBNET" --output json 2>/dev/null | jq -r '."data"."route-table-id"')
HAS_ROUTE=$(oci network route-table get --rt-id "$RT" --output json 2>/dev/null | jq -r --arg i "$IGW" '[."data"."route-rules"[]? | select(."network-entity-id"==$i)] | length')
if [ "${HAS_ROUTE:-0}" = "0" ]; then
  say "adding default route"
  echo "{\"rtId\":\"$RT\",\"routeRules\":[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]}" > /tmp/rt.json
  oci network route-table update --force --from-json "file:///tmp/rt.json" >/dev/null 2>&1 || true
fi

SL=$(oci network subnet get --subnet-id "$SUBNET" --output json 2>/dev/null | jq -r '."data"."security-list-ids"[0]')
HAS_SSH=$(oci network security-list get --security-list-id "$SL" --output json 2>/dev/null | jq -r '[."data"."ingress-security-rules"[]? | select(.source=="0.0.0.0/0" and .protocol=="6" and ((."tcp-options" // {} | ."destination-port-range" // {} | .min) == 22))] | length')
if [ "${HAS_SSH:-0}" = "0" ]; then
  say "adding SSH 22 ingress"
  OLD=$(oci network security-list get --security-list-id "$SL" --output json 2>/dev/null)
  RULES=$(echo "$OLD" | jq -c '
    [."data"."ingress-security-rules"[]
      | select(.protocol == "6")
      | {protocol, source, sourceType: ."source-type",
         tcpOptions: {destinationPortRange: (."tcp-options"."destination-port-range" // {min: 0, max: 65535})}}
    ]
    + [{"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK",
        "tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]')
  echo "{\"securityListId\":\"$SL\",\"ingressSecurityRules\":$RULES}" > /tmp/sl.json
  oci network security-list update --force --from-json "file:///tmp/sl.json" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 4. hunt
KEYFILE=$(mktemp); printf '%s\n' "$VM_SSH_PUBKEY" | sed 's/\r$//' > "$KEYFILE"
ADS=$(oci iam availability-domain list --output json 2>/dev/null | jq -r '.data[].name')
LAUNCHED=""

# GitHub's cron can delay/drop scheduled runs, so each firing makes multiple
# real launch attempts (6 tries ~= 12 min) instead of a single shot.
for TRY in 1 2 3 4 5 6; do
  for AD in $ADS; do
    say "[try $TRY - ${TRIGGER:-manual}] trying $AD ..."
    SOAP=$(mktemp); SERR=$(mktemp)
    if oci compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$TENANCY" \
        --subnet-id "$SUBNET" \
        --image-id "$IMG" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$OCPU,\"memoryInGBs\":$MEM}" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --ssh-authorized-keys-file "$KEYFILE" \
        --output json >"$SOAP" 2>"$SERR"; then
      LAUNCHED=$(jq -r '.data.id' "$SOAP" 2>/dev/null)
      say "LAUNCHED in $AD: $LAUNCHED"
      break
    fi
    if grep -qiE 'out of host capacity|out of capacity|not have enough capacity|429|TooManyRequests|500 Internal' "$SERR"; then
      say "no capacity in $AD (expected)"
    else
      say "unexpected error: $(tail -c 300 "$SERR" | tr '\n' ' ')"
    fi
  done
  [ -n "${LAUNCHED:-}" ] && break
  [ "$TRY" -lt 6 ] && sleep 30
done

if [ -z "${LAUNCHED:-}" ]; then
  say "RESULT: no A1 capacity anywhere (green exit, retry in 5 min)"
  rm -f "$KEYFILE" "$SOAP" "$SERR" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------- 5. fetch IP + notify
say "waiting for RUNNING ..."
for i in $(seq 1 40); do
  sleep 15
  ST=$(oci compute instance get --instance-id "$LAUNCHED" --output json 2>/dev/null | jq -r '."data"."lifecycle-state"')
  [ "$ST" = "RUNNING" ] && break
  echo "    state: $ST"
done

IP=$(oci compute instance list-vnics --instance-id "$LAUNCHED" --output json 2>/dev/null | jq -r '."data"[0]."public-ip"')
say "PUBLIC IP: $IP"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode=HTML \
    -d text="🎉 A1 acquired! %0ARiya A1 instance is RUNNING%0AIP: <code>${IP:-?}</code>%0ADeploy with: .\\deploy\\push.ps1 -VmHost ${IP:-?}" \
    >/dev/null 2>&1 || say "telegram notify failed (non-fatal)"
fi

printf '{"result": "launched", "instance": "%s", "ip": "%s"}\n' "$LAUNCHED" "${IP:-?}" > hunt-result.json
rm -f "$KEYFILE"
say "done"

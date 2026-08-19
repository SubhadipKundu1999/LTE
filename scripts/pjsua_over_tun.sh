#!/usr/bin/env bash
# Register pjsua as Asterisk 1001 using the srsUE internet PDN (tun_srsue).
# Run on PC-1 after attach with apn=internet.
set -euo pipefail

ASTERISK="${ASTERISK_HOST:-10.195.138.20}"
TUN="${TUN_IF:-tun_srsue}"
USER="${SIP_USER:-1001}"
PASS="${SIP_PASS:-1001pass}"
LOCAL_PORT="${LOCAL_PORT:-5062}"

if ! ip link show "$TUN" >/dev/null 2>&1; then
  echo "Interface $TUN not found. Attach srsUE with apn=internet first." >&2
  exit 1
fi

UE_IP="$(ip -4 -o addr show "$TUN" | awk '{print $4}' | cut -d/ -f1 | head -1)"
if [[ -z "$UE_IP" ]]; then
  echo "No IPv4 on $TUN." >&2
  exit 1
fi

echo "Using $TUN addr $UE_IP -> registrar $ASTERISK (SIP $USER)"

# Prefer LTE path for packets sourced from the PDN address.
if ! ip rule show | grep -q "from $UE_IP lookup 100"; then
  ip rule add from "$UE_IP" table 100 || true
fi
ip route replace default dev "$TUN" table 100 || true

if ! command -v pjsua >/dev/null 2>&1; then
  echo "Install pjsua (e.g. sudo apt install pjsua) then re-run." >&2
  echo "Linphone alternative: account $USER@$ASTERISK UDP password $PASS, bind $TUN." >&2
  exit 1
fi

exec pjsua \
  --id "sip:${USER}@${ASTERISK}" \
  --registrar "sip:${ASTERISK}" \
  --realm '*' \
  --username "$USER" \
  --password "$PASS" \
  --local-port "$LOCAL_PORT" \
  --bound-addr "$UE_IP" \
  --ip-addr "$UE_IP"

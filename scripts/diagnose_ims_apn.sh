#!/usr/bin/env bash
# Collect evidence when srsUE disconnects after apn=ims.
# Run pieces on the correct PC (comments say which). Safe if docker is absent.
set -u

echo "=== diagnose_ims_apn $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname) ==="

have() { command -v "$1" >/dev/null 2>&1; }

echo
echo "--- Expected lab default ---"
echo "srsUE [nas] apn must be 'internet' (IPv4)."
echo "APN 'ims' is a second PDN (QCI 5) for COTS VoLTE / experiments, not the srsUE attach APN."

if have ip; then
  echo
  echo "--- tun_srsue (PC-1) ---"
  ip addr show tun_srsue 2>/dev/null || echo "no tun_srsue (UE not attached or not this host)"
fi

if have docker; then
  echo
  echo "--- PC-1 container logs (ignore if not this host) ---"
  docker logs srsue_zmq 2>&1 | tail -40 || true
  echo
  echo "--- PC-2 EPC (ignore if not this host) ---"
  for c in mme smf pcrf upf; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      echo ">> $c"
      docker logs "$c" 2>&1 | grep -iE 'ims|dnn|apn|pcrf|reject|fail|ogstun|session' | tail -15 || true
    fi
  done
  echo
  echo "--- UPF tunnels ---"
  docker exec upf ip addr show ogstun 2>/dev/null || true
  docker exec upf ip addr show ogstun2 2>/dev/null || echo "ogstun2 missing or no upf container"
fi

for f in srslte/ue.log srslte/enb.log; do
  if [[ -f "$f" ]]; then
    echo
    echo "--- $f (tail) ---"
    grep -iE 'NAS|ESM|EMM|RRC|QCI|bearer|detach|release|ERAB' "$f" | tail -25 || true
  fi
done

echo
echo "--- Next ---"
echo "1. Set apn=internet, confirm 192.168.100.x and ping."
echo "2. If testing ims attach: subscriber APN ims IPv4, PCRF up, eNB drb QCI 5, ogstun2 up."
echo "3. SIP to a desk phone: Asterisk + pjsua on tun_srsue (see README_IMS_APN_DISCONNECT_AND_ASTERISK.md)."
echo "4. IMS AKA: Kamailio P-CSCF, not Asterisk."

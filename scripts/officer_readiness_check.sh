#!/usr/bin/env bash
# Officer evidence collector for Open5GS EPC + Kamailio IMS (PC-2).
# Run from the docker_open5gs clone that has 4g-volte-deploy.yaml, e.g.:
#   bash officer_readiness_check.sh
# Optional:
#   UE2_PDN_IP=192.168.100.3 bash officer_readiness_check.sh
#   COMPOSE_FILE=/path/to/4g-volte-deploy.yaml bash officer_readiness_check.sh

set -u

COMPOSE_FILE="${COMPOSE_FILE:-4g-volte-deploy.yaml}"
PC2_LAN="${PC2_LAN:-10.195.138.20}"
PC1_LAN="${PC1_LAN:-10.195.138.30}"
PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
hdr()  { echo; echo "=== $* ==="; }

have() { command -v "$1" >/dev/null 2>&1; }

container_up() {
  local name="$1"
  docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E "^${name}[[:space:]]" | grep -qi 'up'
}

compose_svc_up() {
  local svc="$1"
  if have docker && docker compose version >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}} {{.Status}}' 2>/dev/null \
      | grep -iE "(^${svc}[[:space:]]|${svc}[-_])" | grep -qi 'up' && return 0
  fi
  container_up "$svc"
}

echo "Officer readiness check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host: $(hostname)  cwd: $(pwd)"
echo "Compose file: ${COMPOSE_FILE} (exists: $([[ -f $COMPOSE_FILE ]] && echo yes || echo no))"
echo "Expected PC-2 LAN ${PC2_LAN}  PC-1 LAN ${PC1_LAN}"

# --- Claim 1: EPC ---
hdr "CLAIM 1 — EPC is ready"

if ! have docker; then
  fail "docker not installed on this host (run this on PC-2)"
else
  pass "docker is available"
fi

EPC_SVCS=(mongo webui mme hss sgwc sgwu smf upf pcrf)
for s in "${EPC_SVCS[@]}"; do
  if compose_svc_up "$s"; then
    pass "EPC service running: $s"
  else
    fail "EPC service not Up: $s"
  fi
done

if ss -ln 2>/dev/null | grep -q 36412 || ss -Sln 2>/dev/null | grep -q 36412; then
  pass "MME S1AP port 36412 is listening on this host"
else
  fail "MME S1AP port 36412 not listening (publish 36412/sctp on PC-2)"
fi

if ss -lnu 2>/dev/null | grep -q 2152; then
  pass "SGWU GTP-U port 2152/udp is listening on this host"
else
  fail "SGWU GTP-U port 2152/udp not listening (publish 2152/udp on PC-2)"
fi

if curl -fsS -o /dev/null -I --max-time 5 "http://${PC2_LAN}:9999" 2>/dev/null \
   || curl -fsS -o /dev/null -I --max-time 5 "http://127.0.0.1:9999" 2>/dev/null; then
  pass "Open5GS WebUI HTTP responds (:9999)"
else
  warn "WebUI :9999 did not respond (container may still be Up)"
fi

if ping -c 1 -W 2 "$PC1_LAN" >/dev/null 2>&1; then
  pass "PC-1 ${PC1_LAN} is reachable from this host"
else
  warn "PC-1 ${PC1_LAN} not reachable (OK if you are not on the lab LAN)"
fi

# --- Claim 2: Kamailio + EPC integration ---
hdr "CLAIM 2 — Kamailio IMS integrated with EPC"

IMS_SVCS=(pcscf icscf scscf pyhss dns mysql rtpengine)
for s in "${IMS_SVCS[@]}"; do
  if compose_svc_up "$s"; then
    pass "IMS service running: $s"
  else
    fail "IMS service not Up: $s"
  fi
done

if curl -fsS -o /dev/null -I --max-time 5 "http://${PC2_LAN}:8080/docs/" 2>/dev/null \
   || curl -fsS -o /dev/null -I --max-time 5 "http://127.0.0.1:8080/docs/" 2>/dev/null; then
  pass "pyHSS API docs respond (:8080) — IMS subscriber DB reachable"
else
  warn "pyHSS :8080/docs/ did not respond"
fi

PCSCF_HINT=""
if [[ -f smf/smf_4g.yaml ]] && grep -qi 'p-cscf\|pcscf' smf/smf_4g.yaml; then
  pass "SMF config references P-CSCF (EPC PCO / IMS discovery)"
  PCSCF_HINT=$(grep -i -A3 -E 'p-cscf|pcscf' smf/smf_4g.yaml | head -20)
  echo "$PCSCF_HINT" | sed 's/^/           /'
elif [[ -f .env ]] && grep -qi 'PCSCF' .env; then
  pass ".env defines PCSCF (EPC can advertise P-CSCF to UE)"
  grep -i 'PCSCF' .env | sed 's/^/           /'
else
  warn "Could not find P-CSCF in smf/smf_4g.yaml or .env (check clone path)"
fi

if docker exec pcscf sh -c 'command -v ss >/dev/null && ss -lnu | grep -q 5060' 2>/dev/null \
   || docker exec pcscf sh -c 'netstat -lnu 2>/dev/null | grep -q 5060' 2>/dev/null; then
  pass "P-CSCF is listening on SIP 5060/udp inside the pcscf container"
else
  warn "Could not confirm SIP 5060 inside pcscf (container name or tools missing)"
fi

echo
echo "  Integration reminder (officer talking points):"
echo "    1) Same compose file starts Open5GS EPC and Kamailio CSCFs"
echo "    2) SMF P-CSCF / PCO is how EPC points the UE at IMS"
echo "    3) Live proof of Cx is REGISTER 401 then 200 OK in sngrep (not this script)"

# --- Claim 3: two-UE user/data plane ---
hdr "CLAIM 3 — User / data plane between two UEs"

echo "  Automated host checks cannot fully prove two UEs from PC-2 alone."
echo "  This section records what is present and prints the live commands to run."

if docker logs mme 2>/dev/null | grep -qiE 'attach|imsi|enb'; then
  pass "MME logs show attach/eNB activity (control plane has been used)"
else
  warn "MME logs have no obvious attach/eNB lines yet — start srsENB/srsUE on PC-1"
fi

if docker logs sgwu 2>/dev/null | grep -qiE 'gtp|peer|upf' \
   || docker logs upf 2>/dev/null | grep -qiE 'gtp|ogstun|session'; then
  pass "SGWU/UPF logs show user-plane session activity"
else
  warn "No clear GTP/session lines in sgwu/upf logs yet"
fi

if docker exec upf ip addr show ogstun 2>/dev/null | grep -q inet; then
  pass "UPF ogstun has an IPv4 address (internet PDN / data plane)"
  docker exec upf ip addr show ogstun 2>/dev/null | grep inet | sed 's/^/           /'
else
  warn "Could not show UPF ogstun IPv4 (name may differ; inspect: docker exec upf ip addr)"
fi

if docker exec upf ip addr show ogstun2 2>/dev/null | grep -q inet; then
  pass "UPF ogstun2 has an IPv4 address (ims PDN toward P-CSCF)"
  docker exec upf ip addr show ogstun2 2>/dev/null | grep inet | sed 's/^/           /'
else
  warn "ogstun2 not visible — IMS PDN interface may use another name"
fi

echo
echo "  LIVE TEST A — Internet data plane (one UE, PC-1):"
echo "      docker exec srsue_zmq ping -c 4 8.8.8.8"
echo "  LIVE TEST B — Two-UE data plane (replace IPs from each tun_srsue):"
echo "      docker exec srsue_zmq ping -c 4 \${UE2_PDN_IP:-192.168.100.3}"
echo "  LIVE TEST C — Two-UE IMS user plane (PC-2):"
echo "      sudo sngrep"
echo "      Expect: REGISTER→401→REGISTER→200 OK  (both users)"
echo "      Then:   INVITE→180/200 OK→ACK  (optional RTP)"

if [[ -n "${UE2_PDN_IP:-}" ]]; then
  echo
  echo "  UE2_PDN_IP=${UE2_PDN_IP} was set; this host will try one ping (may fail if not a UE):"
  if ping -c 2 -W 2 "$UE2_PDN_IP" >/dev/null 2>&1; then
    pass "Host can ping ${UE2_PDN_IP} (only meaningful if this is via UPF, not a random LAN host)"
  else
    warn "Host ping to ${UE2_PDN_IP} failed — run ping from UE-1 TUN, not from PC-2 LAN"
  fi
fi

hdr "SUMMARY"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "  Core containers/ports look ready for the officer demo."
  echo "  Complete LIVE TEST A/B/C in OFFICER_DEMO_EPC_IMS_TWO_UE.md for two-UE proof."
  exit 0
else
  echo "  Fix FAIL items before claiming EPC/IMS ready. See README.md section 27."
  exit 1
fi

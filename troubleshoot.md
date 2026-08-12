# Troubleshoot: UE attaches, then goes RRC IDLE

**Lab context:** Two-PC LTE + IMS setup from [`OLDREADME.md`](./OLDREADME.md)  
**PC-1 (RAN+UE):** `10.195.138.30` — srsENB ZMQ + srsUE ZMQ  
**PC-2 (EPC+IMS):** `10.195.138.20` — Open5GS + Kamailio IMS

---

## Symptom you reported

After EPC+IMS and eNodeB are up, the UE attaches once, then soon shows **RRC IDLE**. eNB console looks like:

```text
=== eNodeB started ===
RACH: tti=821, cc=0, pci=1
User 0x46 connected
Disconnecting rnti=0x46
RRC Connection Release.
```

UE side typically ends with:

```text
RRC Connected
...
Received RRC Connection Release
RRC IDLE
```

Power-cycling / restarting the UE often leaves it stuck showing **RRC IDLE** (no lasting RRC Connected).

---

## First decision: is IDLE normal or a failure?

In LTE, **RRC IDLE after a successful attach is often normal**.

| State | Meaning |
|-------|---------|
| **RRC Connected** | Radio link active (user/control plane over air) |
| **RRC IDLE** | Radio released; UE can still be **EMM-REGISTERED** (attached to EPC) |
| **Detached / Attach failed** | Not registered; no usable PDN / no `tun_srsue` IP |

eNB releases RRC when its **RRC inactivity timer** expires (no UL/DL traffic). Default in srsENB is typically:

```ini
# srslte/enb_zmq.conf  →  [expert]
rrc_inactivity_timer = 30000   # milliseconds (30 s)
```

So the sequence **Attach → Connected → (idle timeout) → RRC Connection Release → RRC IDLE** is expected if you are not generating traffic.

**Your job in troubleshooting is to distinguish:**

1. **Healthy IDLE** — attached, IP present, ping wakes RRC again  
2. **Broken IDLE** — never got IP / attach failed / restart cannot re-attach / S1 or ZMQ broken

---

## Step 0 — Capture facts while the problem is happening

Keep three consoles open.

### PC-1 — eNB

```bash
cd ~/docker_open5gs
docker logs -f srsenb_zmq
# also:
tail -f srslte/enb.log
```

### PC-1 — UE

```bash
docker logs -f srsue_zmq
# also:
tail -f srslte/ue.log
```

### PC-2 — MME / HSS

```bash
cd ~/docker_open5gs
docker logs -f mme
docker logs hss 2>&1 | tail -100
```

Record answers to:

1. Did UE ever print **Attach successful** / get **IP `192.168.100.x`**?
2. How long between `User 0x.. connected` and `Disconnecting rnti=...`? (~30s → inactivity; ~1s → likely NAS/S1 failure, not idle timer)
3. After IDLE, does `tun_srsue` still have an IP?
4. After UE restart, do you see a new **RACH** on eNB?

---

## Step 1 — Check if the UE is still attached (healthy IDLE test)

**Run on PC-1** right after you see RRC IDLE (do **not** restart UE yet):

```bash
docker exec -it srsue_zmq ip addr show
docker exec -it srsue_zmq ip route
docker exec -it srsue_zmq ping -c 5 8.8.8.8
```

### Outcome A — IP present and ping works

Example: `tun_srsue` has `192.168.100.x`, ping replies.

**Verdict:** Attach succeeded. RRC release was **user inactivity**. This is not an EPC failure.

**Fixes / workarounds:**

1. **Keep the bearer awake** while testing:

```bash
docker exec -it srsue_zmq ping 8.8.8.8
```

2. **Raise inactivity timer** on PC-1 in `srslte/enb_zmq.conf` under `[expert]`:

```ini
[expert]
rrc_inactivity_timer = 3600000   # 1 hour (ms)
```

Then restart eNB + UE (order matters — see Step 5):

```bash
cd ~/docker_open5gs
docker compose -f srsue_zmq.yaml down
docker compose -f srsenb_zmq.yaml down
set -a; source .env; set +a
docker compose -f srsenb_zmq.yaml up -d
# wait for S1 Setup success, then:
docker compose -f srsue_zmq.yaml up -d
```

3. Expect UE logs to show **RRC Connected** again when MO data (ping) starts a **Service Request**.

If ping from IDLE works, you can stop here for “goes to idle” — that part is normal LTE.

---

### Outcome B — No IP / ping fails / Attach never completed

**Verdict:** Not healthy IDLE. Continue with Steps 2–6.

---

## Step 2 — Classify the release using timing and logs

### Pattern 1 — Release after ~10–60 seconds of silence

```text
User 0x46 connected
... (quiet) ...
Disconnecting rnti=0x46
RRC Connection Release
```

eNB log / S1AP often mentions **user inactivity**.

→ Use Step 1 Outcome A fixes (`rrc_inactivity_timer`, continuous ping).

### Pattern 2 — Release within ~1–2 seconds (matches a “flash” connect)

```text
[18:21:04] User 0x46 connected
[18:21:05] Disconnecting rnti=0x46
[18:21:05] RRC Connection Release
```

This is **usually not** the 30s inactivity timer. Check UE + MME for:

| UE log clue | Likely cause |
|-------------|--------------|
| `Attach failed` / `Authentication failure` | IMSI/K/OP-OPc mismatch vs Open5GS |
| `PLMN not found` / wrong TAC | MCC/MNC/TAC mismatch |
| `Received RRC Connection Release` with no Attach Accept | MME rejected or S1 path broken mid-procedure |
| ZMQ / RF disconnect messages | Start order / ZMQ ports / eNB died |

On PC-2:

```bash
docker logs mme 2>&1 | grep -Ei 'attach|auth|reject|imsi|error|fail' | tail -50
docker logs hss 2>&1 | tail -80
```

Confirm subscriber (see OLDREADME §11):

* IMSI `001011234567895`
* Same K / OP-OPc as `UE1_KI` / `UE1_OP` on PC-1 `.env`
* APN `internet` present on subscriber

---

## Step 3 — Confirm S1 is still up (eNB ↔ MME)

RRC IDLE while eNB has **lost S1** looks like “UE stuck idle” after restart.

**PC-1 eNB logs — required success:**

```text
S1 Setup completed / S1 connected toward 10.195.138.20
```

**PC-2:**

```bash
ss -lntup | grep -E '36412|2152'
docker compose -f 4g-volte-deploy.yaml ps
ping -c 3 10.195.138.30
```

**PC-1:**

```bash
ping -c 3 10.195.138.20
grep -E 'MME_IP|SGWU|SRS_ENB|SRS_UE' .env
```

Must match OLDREADME multihost rules:

| Variable | PC-1 | PC-2 |
|----------|------|------|
| `MME_IP` | **`10.195.138.20`** (not `172.22.0.9`) | `172.22.0.9` (container) |
| `SGWU_ADVERTISE_IP` | unused by eNB | **`10.195.138.20`** |
| `SRS_ENB_IP` / `SRS_UE_IP` | `10.195.138.30` | — |

If S1 is down, fix EPC publish ports / `MME_IP` / firewall before blaming RRC IDLE:

```bash
# PC-2 — UFW and forwarding (OLDREADME)
sudo ufw disable
sudo sysctl -w net.ipv4.ip_forward=1
sudo modprobe sctp
```

Capture S1AP if needed:

```bash
# either PC
sudo tcpdump -ni any sctp -w /tmp/s1ap.pcap
```

---

## Step 4 — “I power UE off/on and it stays RRC IDLE”

Restarting only the UE is fragile in the ZMQ lab. Work through this checklist.

### 4.1 Did eNB still receive RACH after restart?

Watch eNB while restarting UE:

```bash
docker compose -f srsue_zmq.yaml restart
# or down/up:
docker compose -f srsue_zmq.yaml down
docker compose -f srsue_zmq.yaml up -d
docker logs -f srsenb_zmq
```

| What you see on eNB | Meaning |
|---------------------|---------|
| New `RACH:` + `User 0x.. connected` | Radio OK; problem is NAS/attach or quick release |
| **No RACH at all** | ZMQ RF broken or UE not camping |

### 4.2 ZMQ RF — most common restart failure

eNB must be running **before** UE. ZMQ ports (host network):

```text
eNB TX  tcp://10.195.138.30:2000  ←→  UE RX
UE  TX  tcp://10.195.138.30:2001  ←→  eNB RX
```

If you restarted things out of order, or eNB has `fail_on_disconnect=true` and already exited:

```bash
docker ps -a | grep -E 'srsenb|srsue'
docker logs srsenb_zmq 2>&1 | tail -40
```

**Clean RF restart (recommended):**

```bash
cd ~/docker_open5gs
set -a; source .env; set +a
docker compose -f srsue_zmq.yaml down
docker compose -f srsenb_zmq.yaml down
docker compose -f srsenb_zmq.yaml up -d
docker logs -f srsenb_zmq   # wait until S1 is UP, then Ctrl+C
docker compose -f srsue_zmq.yaml up -d
docker logs -f srsue_zmq
```

### 4.3 UE camps but never leaves IDLE

Healthy camp + attach should show roughly:

```text
Found Cell ...
Found PLMN ...
Random Access Complete ...
RRC Connected
...
Network attach successful / IP: 192.168.100.x
```

If you only see cell/PLMN then **RRC IDLE** with no attach:

* Subscriber missing / wrong K-OP
* APN `internet` missing
* MME overloaded / not running
* TAC/PLMN mismatch (`TAC=1`, MCC/MNC `001`/`01`)

```bash
# PC-2
docker logs mme 2>&1 | tail -100
# PC-1
grep -E 'UE1_IMSI|UE1_KI|UE1_OP|MCC|MNC|TAC' .env
```

### 4.4 UE was IDLE (still registered) then you killed the container

Soft UE state is lost when the container stops. On next start it must **attach again** (not merely “wake from IDLE”). If eNB/MME still hold an old context, a clean restart of **UE then eNB** (or full PC-1 stack as in 4.2) clears stale RNTI/S1 UE context.

---

## Step 5 — Correct startup order (from OLDREADME)

Always:

1. **PC-2** EPC+IMS healthy  
2. **PC-1** eNB → wait for **S1 Setup success**  
3. **PC-1** UE  
4. Immediately verify IP + ping (so you know Connected vs IDLE)

```bash
# --- PC-2 ---
cd ~/docker_open5gs
sudo sysctl -w net.ipv4.ip_forward=1
set -a; source .env; set +a
docker compose -f 4g-volte-deploy.yaml up -d
docker compose -f 4g-volte-deploy.yaml ps

# --- PC-1 ---
cd ~/docker_open5gs
set -a; source .env; set +a
docker compose -f srsenb_zmq.yaml up -d
docker logs -f srsenb_zmq    # confirm S1, then Ctrl+C
docker compose -f srsue_zmq.yaml up -d
docker logs -f srsue_zmq
docker exec -it srsue_zmq ping -c 3 8.8.8.8
```

Shutdown order (UE first):

```bash
docker compose -f srsue_zmq.yaml down
docker compose -f srsenb_zmq.yaml down
```

---

## Step 6 — Packet captures when logs are unclear

### Control plane (attach / release cause)

```bash
# PC-1 or PC-2
sudo tcpdump -ni any sctp -w /tmp/s1ap_rrc_idle.pcap
```

Wireshark: decode SCTP PPID as S1AP. Look for:

* `Initial UE Message` / `Attach Request`  
* `Downlink NAS Transport` Attach Accept  
* `UE Context Release` — **cause** (`user-inactivity` vs `radio-connection-with-ue-lost` vs NAS cause)

### User plane (after attach)

```bash
sudo tcpdump -ni any udp port 2152 -w /tmp/gtpu.pcap
```

Expect GTP-U between `10.195.138.30` ↔ `10.195.138.20` when pinging.

### Raise srsRAN log detail temporarily

In `srslte/enb_zmq.conf` and `srslte/ue_zmq.conf`:

```ini
[log]
all_level = info
# or for deeper: all_level = debug
```

Restart eNB/UE, reproduce once, then set back to `warning` (debug is huge).

---

## Quick symptom → fix table

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Attach OK, IP OK, then RRC IDLE after ~30s | RRC inactivity timer | Increase `rrc_inactivity_timer`; keep ping running |
| IDLE but `ping 8.8.8.8` from UE works | Healthy ECM-IDLE | No bug; optional longer timer |
| Connect then Disconnect in ~1s | Auth/attach reject or S1 issue | Fix subscriber K/OP; check `docker logs mme` |
| Restart UE → stuck RRC IDLE, **no RACH** | ZMQ / start order / eNB dead | Full eNB→UE restart; fix ZMQ IPs |
| Restart UE → RACH + quick release again | NAS/subscriber/APN | Align IMSI/K/OP + APN `internet` |
| Attach OK, IDLE, ping fails | User plane (`SGWU_ADVERTISE_IP`, GTP-U) | Set advertise IP to `10.195.138.20`; publish UDP/2152 |
| eNB never S1-connects | `MME_IP` still Docker IP | PC-1 `MME_IP=10.195.138.20` + publish SCTP/36412 |
| Only first boot works | Stale UE context / ZMQ disconnect | Always `down` UE then eNB; bring eNB up before UE |

---

## Minimal “is my lab OK?” checklist after seeing RRC IDLE

- [ ] PC-2: `mme`, `hss`, `sgwu`, `smf`, `upf` are Up  
- [ ] PC-1 eNB: S1 connected to `10.195.138.20`  
- [ ] UE once showed Attach success + `192.168.100.x`  
- [ ] While IDLE (without restart): `docker exec -it srsue_zmq ping -c 3 8.8.8.8`  
- [ ] If you need long Connected time: `rrc_inactivity_timer` raised + traffic  
- [ ] After any restart: **eNB first, UE second**  
- [ ] IMSI/K/OP match Open5GS WebUI/Mongo  

---

## Related docs

* [`OLDREADME.md`](./OLDREADME.md) — full two-PC setup (§21–23 attach/data, §26–27 captures/errors, §28 startup)  
* [`README.md`](./README.md) — same tutorial with beginner links  
* [`README_BEGINNER_LTE_EPC_IMS.md`](./README_BEGINNER_LTE_EPC_IMS.md) — attach vs user-plane concepts  

---

## Bottom line

**Seeing `Disconnecting rnti=...` / `RRC Connection Release` / `RRC IDLE` after a good attach usually means the eNB released the radio for inactivity — the UE can still be attached.**

Prove it with IP + ping from the UE container **without** restarting. Only if attach never completes, release happens in ~1s, or restart never produces RACH/Attach, treat it as a real fault and work Steps 2–5 (S1, subscriber, ZMQ order).

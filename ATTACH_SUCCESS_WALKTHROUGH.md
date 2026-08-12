# Worked example: your EPC attach logs (success → RRC IDLE)

This walks through a **real** two-PC lab capture (PC-1 `10.195.138.30`, PC-2 `10.195.138.20`).

**Verdict first:** LTE attach **succeeded**. The later **RRC IDLE** is normal radio inactivity (~30s), not an EPC failure. S1 stayed up. Next prove user plane with ping.

---

## Timeline (from your logs)

| Time (local) | Where | What happened |
|--------------|-------|----------------|
| 14:26 | PC-2 | MME/HSS/SGWU/UPF started; Diameter MME↔HSS connected |
| 17:38:24 | MME | eNB S1 accepted from `10.195.138.30` — **S1 up** |
| 17:41:26 | MME | `InitialUEMessage` for IMSI `001011234567895` |
| 17:41:27 | UE / UPF / SGWU | Attach complete; UE IP `192.168.100.2` on APN `internet` |
| 17:41:27 | UPF | Harmless IPv6 drop (see below) |
| 17:42:00 | MME / UE | UE Context Release → **RRC IDLE** (~33s after attach) |
| 17:42+ | PC-1 tcpdump | SCTP heartbeats MME↔eNB still OK |

---

## 1. Control plane — attach is good

### eNB joined MME

```text
eNB-S1 accepted[10.195.138.30]:39878
[Added] Number of eNBs is now 1
```

### UE attach

```text
InitialUEMessage
IMSI[001011234567895]
EBI allocated [5]
Attach complete
```

### UE console (matching)

```text
Network attach successful. IP: 192.168.100.2
```

### User plane session created

```text
# SGWU
UE F-SEID[...]
gtp_connect() [10.195.138.30]:2152

# UPF
APN[internet] PDN-Type[1] IPv4[192.168.100.2]
```

`PDN-Type[1]` = **IPv4 only**. Pool matches SMF/UPF `ogstun` (`192.168.100.0/24`).

HSS showing only startup + Diameter connect (no noisy auth lines) is fine when attach already completed.

---

## 2. RRC IDLE — usually not a bug

### What you saw

**UE (~33s later):**

```text
Received RRC Connection Release (releaseCause: other)
RRC IDLE
```

**MME:**

```text
UE Context Release [Action:2]
Mobile Reachable timer started for IMSI[001011234567895]
[Removed] Number of eNB-UEs is now 0
```

### Meaning

| Term | Meaning |
|------|---------|
| **RRC Connected** | Radio active |
| **RRC IDLE** | Radio released; UE can still be **EMM-REGISTERED** (attached) |
| **Action:2** + ~30s silence | Typical **user inactivity** release from eNB |
| Mobile Reachable timer | MME still tracks the UE while IDLE |

Default srsENB inactivity is often **30000 ms**. Your gap (17:41:27 → 17:42:00) matches that.

SCTP heartbeats after IDLE prove **S1 is still alive**:

```text
10.195.138.20.36412 ↔ 10.195.138.30.39878  HB REQ / HB ACK
```

---

## 3. Prove healthy IDLE (do this before restarting UE)

**On PC-1** (leave UE running):

```bash
docker exec -it srsue_zmq ip addr show
docker exec -it srsue_zmq ping -c 5 8.8.8.8
```

| Result | Meaning |
|--------|---------|
| `tun_srsue` has `192.168.100.2` and ping works | Healthy IDLE → Service Request wakes RRC |
| No IP / ping fails | User-plane problem (`SGWU_ADVERTISE_IP`, UDP/2152, `ip_forward`) — not “attach failed” |

To stay Connected longer while testing:

```ini
# srslte/enb_zmq.conf  [expert]
rrc_inactivity_timer = 3600000
```

Or keep a ping running in another terminal.

---

## 4. UPF `Invalid packet [IP version:6]` — ignore for IPv4 attach

```text
[upf] ERROR: Invalid packet [IP version:6, Packet Length:48]
0000: 60000000 00083aff ...   # IPv6 + ICMPv6 (e.g. Router Solicitation)
```

Session is **IPv4-only** (`PDN-Type[1]`). Something still sent a small IPv6 ND/RS into GTP-U; UPF correctly drops it. It does **not** undo attach or explain RRC IDLE.

---

## 5. IMS not in this capture (expected)

SMF has `dnn: ims` (`192.168.101.0/24`) and UPF has `ogstun2`, but this attach only created **internet**.

Default srsUE (`ue_zmq.conf`) requests **internet** only — no IMS PDN / SIP REGISTER yet. Finish internet ping first, then IMS steps in [`README.md`](./README.md) §24.

---

## 6. Quick “green lights” checklist from this run

- [x] All `4g-volte-deploy.yaml` services Up  
- [x] Host listens on SCTP/36412, UDP/2152, TCP/9999  
- [x] SMF IMS + internet DNN pools present  
- [x] UPF `ogstun` / `ogstun2` addresses present  
- [x] eNB S1 to MME  
- [x] Attach Accept + UE IP `192.168.100.2`  
- [x] SGWU/UPF session + GTP toward eNB  
- [x] S1 heartbeats after RRC IDLE  
- [ ] **You still need:** ping from UE (and only then IMS)

---

## Related

* [`README.md`](./README.md) §22–23 — attach and data tests  
* [`troubleshoot.md`](./troubleshoot.md) — when IDLE is *not* healthy (auth fail, ~1s release, no RACH after restart)  
* [`README_UE_JOURNEY_LTE_IMS.md`](./README_UE_JOURNEY_LTE_IMS.md) — beginner story of the same path  

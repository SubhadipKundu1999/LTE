# Officer demonstration: EPC ready, Kamailio integrated, two-UE user/data plane

**Audience:** higher officer / reviewer who needs **proof**, not a full lab course.  
**Duration:** about 15 minutes live on the lab PCs.  
**Machines:** PC-1 RAN/UE `10.195.138.30` · PC-2 EPC+IMS `10.195.138.20`

This is the **show script**. Build and config stay in [`README.md`](./README.md). Two-party calling detail stays in [`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md).

Run the evidence collector on **PC-2** from `~/docker_open5gs` (copy `scripts/officer_readiness_check.sh` there):

```bash
bash officer_readiness_check.sh | tee /tmp/officer-readiness-$(date +%Y%m%d-%H%M).log
```

Hand the log plus this document to the officer. Green PASS lines are the claim. Live tests below are the confirmation.

---

## What you are claiming (say this first)

| Claim | What it means in this lab | Proof the officer should see |
|-------|---------------------------|------------------------------|
| **1. EPC is ready** | Open5GS core is up: MME, HSS, SGW, SMF/UPF, PCRF. RAN can attach. | Containers Up; S1 to MME; UE gets `192.168.100.x`; ping works |
| **2. Kamailio is integrated with EPC** | Same compose stack: Kamailio P/I/S-CSCF + pyHSS + IMS DNS. EPC can point the UE at P-CSCF (PCO). SIP rides the IP path EPC created. | `pcscf`/`icscf`/`scscf`/`pyhss`/`dns` Up; P-CSCF IP in SMF; REGISTER `401` then `200 OK` |
| **3. User plane + data plane between two UEs is ready** | **Data plane:** GTP-U through SGWU/UPF; two UEs can ping each other on PDN IPs. **User plane (IMS):** two IMS identities REGISTER and can INVITE (SIP signalling; RTP if media path is published). | Ping `192.168.100.x` ↔ `192.168.100.y`; `sngrep` REGISTER + INVITE |

Say this sentence once so nobody confuses layers:

> EPC is the mobile ISP (SIM auth + IP tunnels). Kamailio IMS is the voice/SIP application **on top of** those tunnels. A ping proves data. A SIP REGISTER/INVITE proves IMS. Both together is the integrated lab.

Do **not** claim commercial VoLTE between two handsets unless Path C (USIM + SDR + VoLTE phones) is actually running. For ZMQ srsUE, claim **LTE data + IMS core integration**; srsUE has **no SIP stack**.

---

## One picture (draw this on the whiteboard / screen)

```text
        CONTROL PLANE                         USER / DATA PLANE
  UE ↔ eNB --S1AP/SCTP--> MME/HSS        UE ↔ eNB --GTP-U/UDP 2152--> SGWU → UPF
                                              │
                                              ├─ internet APN  192.168.100.x  (ping / data)
                                              └─ ims APN       192.168.101.x  → P-CSCF 172.22.0.21
                                                                              → I-CSCF → S-CSCF
                                                                              → pyHSS (Diameter Cx)
```

PC-1 = radio (ZMQ) + first UE.  
PC-2 = **entire** EPC **and** Kamailio IMS. Do not split them for this demo.

---

## Demo 1 — EPC is ready (about 5 minutes)

**Where:** PC-2 first, then PC-1.  
**Talking point:** “Core network is live and serving a subscriber.”

### 1.1 Core processes (PC-2)

```bash
cd ~/docker_open5gs
docker compose -f 4g-volte-deploy.yaml ps
```

Officer should see **Up** for at least:

`mongo`, `webui`, `mme`, `hss`, `sgwc`, `sgwu`, `smf`, `upf`, `pcrf`

### 1.2 Published S1 ports (PC-2)

```bash
ss -ln | grep 36412    # S1AP / SCTP into MME
ss -lnu | grep 2152    # GTP-U into SGWU
curl -I http://10.195.138.20:9999
```

**Pass:** MME listens on `36412`, SGWU on `2152`, WebUI answers.  
Show WebUI subscriber IMSI `001011234567895` with APNs `internet` and `ims`.

### 1.3 Control plane: eNB attached to MME (PC-1 then PC-2)

On PC-1, eNB already running (`srsenb_zmq`). Show log:

```bash
docker logs srsenb_zmq 2>&1 | tail -40
```

**Pass:** S1 Setup successful toward `10.195.138.20`.

On PC-2:

```bash
docker logs mme 2>&1 | tail -40
```

**Pass:** eNB from `10.195.138.30` associated.

### 1.4 User attach + IP (PC-1)

```bash
docker logs srsue_zmq 2>&1 | tail -50
docker exec srsue_zmq ip addr show tun_srsue
```

**Pass:** Attach accepted; TUN has `192.168.100.x`.

### 1.5 Data plane to Internet (PC-1)

```bash
docker exec srsue_zmq ping -c 4 8.8.8.8
```

**Pass:** ICMP replies. That is GTP-U + UPF NAT working.  
If attach works but ping fails, control plane is up and **user plane is not** — do not claim EPC data-ready.

Optional capture (one window, 10 seconds) on either PC:

```bash
sudo timeout 10 tcpdump -ni any udp port 2152 -c 20
```

**Pass:** GTP-U packets between `10.195.138.30` and `10.195.138.20`.

---

## Demo 2 — Kamailio integrated with EPC (about 5 minutes)

**Talking point:** “IMS is not a separate PBX. It is the same stack, and EPC tells the UE how to find it.”

### 2.1 IMS containers on the same compose file (PC-2)

```bash
docker compose -f 4g-volte-deploy.yaml ps
```

**Pass:** `pcscf`, `icscf`, `scscf`, `pyhss`, `dns`, `mysql`, `rtpengine` are **Up**.  
Same YAML as EPC = same deployment, not a second Kamailio on another PC.

### 2.2 Three integration links (show, do not lecture)

| Link | How to show in 30 seconds | Why the officer cares |
|------|---------------------------|------------------------|
| **IP path** | `docker exec pcscf hostname -I` → `172.22.0.21`; UPF `ogstun` / `ogstun2` | SIP only works if EPC already gave the UE an IP path |
| **P-CSCF discovery (PCO)** | `grep -A2 p-cscf smf/smf_4g.yaml` (or SMF env `PCSCF_IP`) | EPC **hands the UE the P-CSCF address** during PDN setup |
| **Policy (Rx)** | `pcscf` started with 4G deploy mode; `pcrf` Up | Voice QoS can ask EPC for a dedicated bearer |

```bash
docker logs smf 2>&1 | grep -i -E 'pcscf|p-cscf|ims' | tail -20
docker logs pcscf 2>&1 | tail -20
docker logs pyhss 2>&1 | tail -20
```

### 2.3 IMS subscriber exists (not only Open5GS HSS)

Open `http://10.195.138.20:8080/docs/` (pyHSS). Confirm AUC + IMS subscriber for:

* IMPI `001011234567895@ims.mnc001.mcc001.3gppnetwork.org`
* IMPU `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org`

**Pass:** LTE HSS **and** pyHSS both provisioned. Missing pyHSS = ping works, REGISTER fails.

### 2.4 SIP REGISTER through Kamailio (live)

Start capture on PC-2:

```bash
sudo sngrep
```

Register one IMS client (Linphone in Docker network, or published `10.195.138.20:5060` — see Path A in the two-UE guide).

**Pass (say it out loud):**

```text
REGISTER  →  401 Unauthorized (IMS AKA)  →  REGISTER  →  200 OK
```

That sequence is **Kamailio + pyHSS Cx**, not Asterisk MD5. A cheap password-only SIP phone that dies on `AKAv1-MD5` is **not** a failed EPC; it is the wrong client.

---

## Demo 3 — User plane and data plane between two UEs (about 5 minutes)

Two different proofs. Do **both** if you can. If you only have one LTE UE, do **3A data** with two attached UEs **or** skip to **3B IMS** with two SIP clients on the same IMS.

### 3A — Data plane: IP between two LTE UEs (GTP-U / PDN)

Requires Path B: second eNB+UE on a spare PC (or second ZMQ pair), both attached to **this** MME, both with `internet` APN.

```text
UE-1  192.168.100.2  --GTP-U-->  UPF  <--GTP-U--  192.168.100.3  UE-2
```

On UE-1 host:

```bash
docker exec srsue_zmq ping -c 4 192.168.100.3
```

(Use the real TUN IPs from `ip addr show tun_srsue` on each UE.)

**Pass:** ICMP between the two PDN addresses.  
That is **UE–UE data plane through EPC**, not LAN ping of `10.195.138.x`.

Also show MME/SMF has **two** attached IMSIs (`001011234567895` and `001011234567896`).

### 3B — User plane (IMS): two users REGISTER and call

Provision UE-2 in pyHSS (`9076543211` / IMSI `001011234567896`). Two Linphone (or IMS-AKA) clients → P-CSCF.

In `sngrep`:

```text
Both:  REGISTER → 401 → REGISTER → 200 OK
Then:  INVITE → 100 Trying → 180 Ringing → 200 OK → ACK
       (optional) RTP via rtpengine
       BYE → 200 OK
```

**Pass:** signalling through **this** P-CSCF/I-CSCF/S-CSCF.  
If SIP 200 OK but no audio: media/RTPEngine/firewall — still claim **user-plane signalling ready**; do not claim voice media until RTP is heard.

### Honest mapping (use this if the officer asks “is it VoLTE?”)

| Setup you actually ran | What you may say |
|------------------------|------------------|
| One srsUE ping + IMS containers Up | EPC data ready; Kamailio **core** integrated; **not** two-UE yet |
| Two srsUE ping each other | **Data plane between two UEs ready** |
| Two Linphone REGISTER/INVITE on P-CSCF | **IMS user plane between two users ready** (not necessarily over LTE radio) |
| Linphone bound to each UE TUN, then INVITE | SIP **on** the LTE user plane (lab VoLTE-like) |
| Two commercial VoLTE phones + USIM + SDR | Closest to operator VoLTE |

---

## Suggested speaking order (keep to this)

1. Architecture picture (30 seconds).  
2. Demo 1.1–1.5: “EPC ready.”  
3. Demo 2.1–2.4: “Same PC-2, Kamailio, PCO, REGISTER 200.”  
4. Demo 3A and/or 3B: “Two users, data and/or SIP.”  
5. Hand over `officer-readiness-*.log` and the `sngrep` / ping screenshot.

---

## Evidence pack (print or screenshot)

| # | Artifact | Claim it supports |
|---|----------|-------------------|
| E1 | `docker compose -f 4g-volte-deploy.yaml ps` | EPC + IMS running together |
| E2 | WebUI subscriber + APNs | EPC provisioning |
| E3 | eNB S1 + UE attach + `tun_srsue` IP | Control plane |
| E4 | `ping 8.8.8.8` from UE | User/data plane (Internet) |
| E5 | `tcpdump` UDP/2152 | GTP-U on the wire |
| E6 | pyHSS IMS subscriber + `sngrep` REGISTER 200 | Kamailio ↔ EPC/IMS path |
| E7 | Ping UE-1 PDN ↔ UE-2 PDN | Two-UE **data** plane |
| E8 | `sngrep` INVITE 180/200 | Two-UE **user** (IMS) plane |

---

## If something is red — what not to say

| Failure | Do not say | Say instead |
|---------|------------|-------------|
| Containers down | “Kamailio is integrated” | “Core not started; start compose first” |
| Attach OK, ping fail | “Data plane ready” | “Control plane only; check `SGWU_ADVERTISE_IP` and UDP 2152” |
| Ping OK, REGISTER fail | “IMS integrated end-to-end” | “EPC data OK; IMS identity/DNS/P-CSCF path still open” |
| Two LAN SIP phones via Asterisk | “VoLTE / Kamailio integration” | That is a PBX demo, not this project |
| One UE only | “Two-UE data plane ready” | Show one-UE data + IMS REGISTER; schedule second UE |

Full command cookbook: [`README.md`](./README.md) sections 22–25 and 30.  
Second UE / SIP phones: [`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md).

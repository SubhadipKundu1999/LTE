# Two-UE / SIP-phone calling in this lab

**How to get a real call (ring + talk) using the Open5GS + Kamailio IMS you already deploy**, extra lab PCs, and SIP phones.

This is the missing “second phone” chapter. Build/run commands for the **one-UE LTE attach** lab stay in [`README.md`](./README.md). Concepts stay in [`README_BEGINNER_LTE_EPC_IMS.md`](./README_BEGINNER_LTE_EPC_IMS.md).

---

## Direct answers

| Question | Answer |
|----------|--------|
| Do we need to write our own Kamailio IMS? | **No.** `4g-volte-deploy.yaml` on PC-2 already starts P-CSCF, I-CSCF, S-CSCF, pyHSS, DNS, MySQL, RTPEngine. Integrate by **using that stack**, not by inventing a second IMS. |
| Can two srsUE processes call each other by themselves? | **No.** srsUE is a **modem** (attach + IP). It has **no SIP / IMS client**. Attach ≠ phone call. |
| Can we use the lab SIP phones? | **Yes, for IMS calling**, if they can do **IMS AKA** (or you use Linphone instead). A cheap MD5-only SIP phone will **not** complete a 3GPP IMS REGISTER. |
| What is the fastest way to hear a call with extra PCs? | Two **Linphone** (or IMS-capable SIP) clients, two pyHSS IMS subscribers, both pointing at **P-CSCF**. |
| What is real VoLTE (UE ↔ UE over LTE)? | Two **IMS-capable phones** (or srsUE **plus** a SIP client using the UE tunnel) with **IMS PDN**, USIM keys matching Open5GS + pyHSS, radio (SDR or two ZMQ eNBs). |

If the goal is **“is this LTE core ready, proven only by UE-to-UE?”** (not LAN SIP phones), read [`README_COMMERCIAL_UE_TO_UE.md`](./README_COMMERCIAL_UE_TO_UE.md) first: Gate 1 is ping between two attached UE IPs; Gate 2 is voice on those tunnels. That proves the **prototype path**, not a commercial operator network.

**Recommended order in your lab**

1. Keep PC-1 / PC-2 LTE data working (attach + ping).  
2. On extra PCs, get **two IMS clients** to REGISTER and **INVITE** through Kamailio (this document, Path A).  
3. Only then add a **second LTE UE** (Path B) or commercial phones (Path C).  
4. For “commercial-shaped” proof, Path B + UE IP ping (and Path B + IMS on the TUN) — not Path A alone.

---

## 1. What “VoLTE” actually is here

```text
VoLTE  =  LTE radio/tunnels  +  IMS SIP call  (same operator IMS)

You already have:
  LTE tunnels  →  Open5GS on PC-2
  IMS SIP      →  Kamailio + pyHSS on PC-2

You still need TWO call endpoints (SIP user agents), not only one srsUE.
```

srsUE on PC-1 proves: SIM auth, S1, GTP-U, internet APN.  
Kamailio proves: SIP REGISTER / INVITE / RTP.  
A **VoLTE call** is both together: the SIP packets travel **inside** the UE’s IMS (or, in a lab shortcut, internet) PDN.

A SIP phone on the LAN talking to P-CSCF is **IMS calling**. That is the right first test. It is not yet “over LTE” unless those SIP packets go through an attached UE tunnel.

---

## 2. What to use extra PCs for

Keep the existing two-PC core. Add clients on spare machines.

| Machine | Role | Software |
|---------|------|----------|
| **PC-1** `10.195.138.30` | RAN + first software UE | srsENB (ZMQ) + srsUE (ZMQ) |
| **PC-2** `10.195.138.20` | EPC + IMS (do not split this) | `docker compose -f 4g-volte-deploy.yaml` |
| **PC-3** (spare) | IMS client #1 **or** second RAN+UE | Linphone **or** second srsENB+srsUE |
| **PC-4** (spare) | IMS client #2 | Linphone / SIP phone |

Do **not** put a second Kamailio on another PC. One IMS core on PC-2 is the integration with this project.

---

## 3. Software UE vs SIP phone vs commercial phone

| Endpoint | LTE attach | SIP / IMS call | Good for |
|----------|------------|----------------|----------|
| **srsUE (ZMQ)** | Yes | No (no IMS stack) | Data, S1, GTP |
| **Linphone / IMS softphone** | No (unless you bind it to a UE TUN) | Yes (if AKA / IMS settings work) | First two-party call |
| **Lab hardware SIP phone** | No | Only if it supports **IMS / AKA**, not only Digest-MD5 | Same as Linphone if IMS-capable |
| **Android / iPhone + programmed USIM + real RF** | Yes | Yes (VoLTE stack in the phone) | Closest to operator VoLTE |

### SIP phone gotcha (read this before you waste a day)

Kamailio IMS in this project challenges with **Digest-AKAv1-MD5** using Ki/OPc from **pyHSS**.  
That is **not** the same as:

* username = `1001`, password = `1234` on Asterisk / FreeSWITCH  
* a Grandstream / Fanvil phone with “SIP registrar = PC-2, password = secret”

If REGISTER dies after `401` with `algorithm=AKAv1-MD5`, the phone cannot do IMS AKA. Install **Linphone** on that PC (or use a phone firmware that documents IMS/AKA).

Linphone account fields that must match pyHSS:

| Linphone / SIP field | Example for UE-1 |
|----------------------|------------------|
| Username / IMPU | `9076543210` or `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org` |
| Auth ID / IMPI | `001011234567895@ims.mnc001.mcc001.3gppnetwork.org` |
| Domain / realm | `ims.mnc001.mcc001.3gppnetwork.org` |
| Proxy / P-CSCF | see Path A (Docker IP vs published host IP) |
| Transport | UDP (lab default, port 5060) |
| Password | **not a random SIP password** — IMS AKA uses the **same K/OPc** as the USIM / pyHSS AUC |

Exact Linphone menu names differ by version. If the client has an **IMS** or **AKA** toggle, enable it. **This must be verified** on the Linphone build you install.

---

## 4. Two subscribers you must provision (both sides)

A call needs **two** IMPUs. Provision **both** in:

1. Open5GS WebUI (if that IMSI will also attach as LTE)  
2. pyHSS: APN (once) → AUC → SUBSCRIBER → IMS_SUBSCRIBER  
3. OsmoHLR MSISDN (if you use the repo SMS path)

| | UE-1 (already in README) | UE-2 (add this) |
|--|--------------------------|-----------------|
| IMSI | `001011234567895` | `001011234567896` |
| K | `8baf473f2f8fd09487cccbd7097c6862` | same K is OK in a closed lab, or pick a second key and **match everywhere** |
| OP | `11111111111111111111111111111111` | same OP |
| OPc | `8e27b6af0e692e750f32667a3b14605d` | recompute if K changes |
| AMF | `8000` | `8000` |
| MSISDN / IMPU number | `9076543210` | `9076543211` |
| IMPI | `001011234567895@ims.mnc001.mcc001.3gppnetwork.org` | `001011234567896@ims.mnc001.mcc001.3gppnetwork.org` |
| IMPU | `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org` | `sip:9076543211@ims.mnc001.mcc001.3gppnetwork.org` |
| APNs | `internet` + `ims` | same |

pyHSS IMS subscriber JSON for UE-2 (IDs from your API — **must be verified**):

```json
{
  "imsi": "001011234567896",
  "msisdn": "9076543211",
  "sh_profile": "string",
  "scscf_peer": "scscf.ims.mnc001.mcc001.3gppnetwork.org",
  "msisdn_list": "[9076543211]",
  "ifc_path": "default_ifc.xml",
  "scscf": "sip:scscf.ims.mnc001.mcc001.3gppnetwork.org:6060",
  "scscf_realm": "ims.mnc001.mcc001.3gppnetwork.org"
}
```

To place a call: UE-1 dials `sip:9076543211@ims.mnc001.mcc001.3gppnetwork.org` (or `9076543211` if the client adds the realm).

---

## 5. Path A — Fastest call: two IMS clients into existing Kamailio (use extra PCs / SIP phones)

This **integrates with the project IMS**. It does **not** require a second srsUE.

```text
PC-3 Linphone/SIP  --SIP REGISTER/INVITE-->  P-CSCF (pcscf)
PC-4 Linphone/SIP  --SIP REGISTER/INVITE-->  P-CSCF (pcscf)
                                              |
                                         I-CSCF → S-CSCF → pyHSS
                                              |
                                         RTPEngine (voice media)
```

### A.1 Confirm IMS is up on PC-2

Same as [`README.md`](./README.md) sections 24–25:

```bash
docker compose -f 4g-volte-deploy.yaml ps
docker logs pcscf --tail 30
docker logs scscf --tail 30
docker logs pyhss --tail 30
```

Need `pcscf`, `icscf`, `scscf`, `pyhss`, `dns`, `mysql`, `rtpengine` **Up**.

### A.2 How the SIP phone reaches P-CSCF

P-CSCF listens **inside Docker** at `172.22.0.21:5060`. Lab SIP phones on `10.195.138.0/24` **cannot** use that address unless you add a path.

Pick **one** method.

#### Method A2-1 (most reliable): clients on the Docker network

On **PC-2**, run two Debian/Ubuntu containers on `docker_open5gs_default` and install Linphone (or use `sngrep` + `pjsua` if you prefer CLI). They can use `172.22.0.21` as P-CSCF with no NAT.

```bash
docker network ls | grep open5gs
```

Attach test clients to that **external** network (`ipv4_address` optional).  
**This must be verified** against the exact compose network name on your PC-2.

Good for: proving REGISTER + INVITE + RTPEngine without fighting Docker DNAT.

#### Method A2-2 (matches “SIP phone on another PC”): publish P-CSCF on PC-2 LAN

On PC-2, in `4g-volte-deploy.yaml` under `pcscf`, publish SIP (uncomment or add — **verify** the compose file on your clone):

```yaml
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
```

Point the SIP phone **registrar / outbound proxy** at:

```text
10.195.138.20:5060
```

RTPEngine must advertise **PC-2’s LAN IP** (`DOCKER_HOST_IP=10.195.138.20`) so media returns to the phones. Publish the RTP UDP range used by `rtpengine` as well, or media will be one-way/silent. Exact port range is in your `rtpengine` compose/env — **This must be verified before continuing.**

Kamailio may still put `172.22.0.21` in SIP headers. If REGISTER works but INVITE/media fails, stay on Method A2-1 first, then fix advertised addresses. Do not invent a second Kamailio to “make SIP easier.”

### A.3 REGISTER success (both phones)

On PC-2:

```bash
sudo sngrep
# or
docker logs -f pcscf
docker logs -f scscf
docker logs -f pyhss
```

Happy path (each client):

```text
REGISTER  →  401 Unauthorized (AKA challenge)  →  REGISTER + response  →  200 OK
```

Both clients must show registered. If only one registers, the other has IMSI/MSISDN/AUC mismatch.

### A.4 Call

From UE-1 client, call UE-2’s MSISDN.

Happy path:

```text
INVITE → 100 Trying → 180 Ringing → 200 OK → ACK
RTP through rtpengine (or end-to-end if your lab skips it)
BYE → 200 OK
```

If signalling is 200 OK but no audio: RTPEngine advertise IP, firewall, or codec mismatch (use PCMU/PCMA first).

---

## 6. Path B — Two software UEs (ZMQ) on extra PCs

ZMQ is a **point-to-point fake cable** on **one PC**:

```text
srsUE  ←tcp://THIS_PC:2000/2001→  srsENB     (cannot stretch that pair to a second PC)
```

You **cannot** put srsUE on PC-3 and attach it to the eNB on PC-1 over ZMQ without extra ZMQ wiring that this tutorial does not use.

**What extra PCs are for (second LTE UE):**

```text
PC-1: srsENB-1 + srsUE-1  --S1-->  PC-2 MME/SGWU
PC-3: srsENB-2 + srsUE-2  --S1-->  PC-2 MME/SGWU  (same Open5GS, same IMS)
```

On PC-3 copy the PC-1 procedure from [`README.md`](./README.md) with these differences:

| Item | PC-1 | PC-3 |
|------|------|------|
| Host LAN IP | `10.195.138.30` | **PC-3’s own LAN IP** |
| `DOCKER_HOST_IP` / `SRS_ENB_IP` / `SRS_UE_IP` | `.30` | PC-3 IP |
| `MME_IP` | `10.195.138.20` | **same** `10.195.138.20` |
| `enb_id` in `enb_zmq.conf` | `0x19B` | **different**, e.g. `0x19C` |
| ZMQ ports | `2000` / `2001` | can stay `2000`/`2001` **on PC-3** (local) |
| IMSI / keys | UE-1 | **UE-2** |

Both eNBs use published `10.195.138.20:36412` (S1AP) and GTP-U to `10.195.138.20:2152`.

After both UEs attach you still **do not have a voice call** until each UE has a SIP client:

* run Linphone **on that RAN PC**, routing SIP via the UE TUN (`tun_srsue`), **or**  
* use a commercial phone (Path C).

Binding Linphone to `tun_srsue` / IMS PDN is OS-routing work and **must be verified** (policy routing so SIP to `172.22.0.21` goes through the tunnel, not the LAN NIC).

Stock `ue_zmq.conf` requests APN `internet` only. A dedicated `ims` PDN is more operator-like; a lab shortcut is SIP over the internet APN toward P-CSCF if routing exists. Operators use `ims` for QoS and no-NAT toward P-CSCF (`ogstun2` in this project).

---

## 7. Path C — Closest to operator VoLTE (commercial UEs)

Need:

* Two phones with **VoLTE** (not only “4G data”)  
* **Programmable USIMs** (sysmoUSIM / similar) written with the same IMSI/K/OP as Open5GS + pyHSS  
* **Real RF**: USRP/LimeSDR on the eNB PC, **or** a small cell, **not** ZMQ  
* Same PC-2 core: Open5GS + Kamailio IMS  
* Phone APN: `internet` + `ims`, IMS domain `ims.mnc001.mcc001.3gppnetwork.org`, P-CSCF from PCO (`PCSCF_IP`)

ZMQ srsUE cannot replace this path. Extra PCs help as eNB hosts or as wired IMS clients (Path A), not as fake commercial modems.

---

## 8. Do not build a second IMS

| Do | Don’t |
|----|--------|
| Use `4g-volte-deploy.yaml` Kamailio on PC-2 | Install another Kamailio/Asterisk on PC-3 “for SIP phones” and call that VoLTE |
| Add IMS subscribers in **pyHSS** | Create only Asterisk extensions `1001`/`1002` |
| Point phones at **P-CSCF** | Point phones at I-CSCF (`4060`) or S-CSCF (`6060`) as a shortcut |
| Publish SIP/RTP on PC-2 if phones are on the LAN | Expect `172.22.0.21` to work from a SIP phone with no route/DNAT |

Asterisk between two SIP phones is a **PBX demo**. It does not exercise Cx, S-CSCF, or this project’s IMS.

---

## 9. Suggested lab days (technical sequence, not calendar)

1. **PC-1/PC-2:** attach + ping (`README.md`).  
2. **pyHSS:** second IMS subscriber (`9076543211`).  
3. **PC-3 + PC-4 or two containers:** Path A REGISTER + call. Capture with `sngrep`.  
4. **Optional:** Path B second eNB+UE on a spare PC; ping between UE IPs (`192.168.100.x`).  
5. **Optional:** Linphone via UE TUN so SIP is on the LTE path.  
6. **Optional:** Path C if you have USIMs + SDR.

---

## 10. Failure map

| Symptom | Layer | Where to look |
|---------|--------|----------------|
| No S1 / no attach | RAN/EPC | PC-1 eNB, MME `36412`, IMSI/K |
| Attach OK, no ping | User plane | `SGWU_ADVERTISE_IP`, UDP `2152` |
| Ping OK, no SIP REGISTER | IMS reachability | route to P-CSCF, published `5060`, DNS |
| `401` then client gives up | Auth algorithm | phone is MD5-only; use Linphone/AKA |
| `403` / no user | Identity | pyHSS IMS_SUBSCRIBER / IMPI / IMPU |
| REGISTER 200, INVITE 404 | Second user | UE-2 not registered or wrong dial string |
| 200 OK, no voice | Media | RTPEngine advertise IP, UDP ports, codec |

---

## 11. Checklist for a two-party IMS call

- [ ] PC-2 `4g-volte-deploy.yaml` IMS containers up (do not build a new IMS)  
- [ ] Two pyHSS IMS subscribers with different MSISDNs  
- [ ] Two IMS-capable clients (Linphone or IMS SIP phones), not MD5-only PBX phones  
- [ ] Both REGISTER `200 OK` in `sngrep` / `pcscf` logs  
- [ ] INVITE from one MSISDN to the other, `180`/`200`, then RTP  
- [ ] (Later) those SIP packets on a UE TUN if you need “over LTE”

When that checklist is green, you have **calling through this project’s Kamailio IMS**. Adding a second srsUE only proves a second **LTE modem**; adding commercial phones + USIM + RF is what turns it into **VoLTE between two UEs**.

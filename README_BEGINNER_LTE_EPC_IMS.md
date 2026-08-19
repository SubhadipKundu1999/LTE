# Beginner Guide: LTE EPC + IMS Integration

**Learning path using your real 2-PC lab**

| Machine | Role | LAN IP |
|---------|------|--------|
| **PC-1** | srsRAN UE + ZMQ eNodeB | `10.195.138.30` |
| **PC-2** | Open5GS EPC + Kamailio IMS | `10.195.138.20` |

This document teaches **concepts**.  
Your step-by-step build/run commands live in [`README.md`](./README.md).  
Prefer a slower narrative first? Start with [`README_UE_JOURNEY_LTE_IMS.md`](./README_UE_JOURNEY_LTE_IMS.md).  
Need **two UEs or SIP phones calling**? See [`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md).

Read this when you feel lost about *why* something exists.  
Use the story guide when you want events in order.  
Use `README.md` when you need to *do* something.

---

## How to use this guide

1. Skim **Section 1** for the big picture.
2. Read **Sections 2–6** before your first attach attempt.
3. Read **Sections 7–11** before IMS / VoLTE work.
4. Use **Section 12** as a glossary while troubleshooting.

You already know Linux. This guide assumes that, and starts where telecom gets confusing: **APN, PDN, IP allocation, IMS, databases, and protocols**.

---

## Table of contents

1. [The big picture in plain language](#1-the-big-picture-in-plain-language)
2. [Actors in your lab](#2-actors-in-your-lab)
3. [What is an APN?](#3-what-is-an-apn)
4. [PDN / PDU sessions — how the UE gets an IP](#4-pdn--pdu-sessions--how-the-ue-gets-an-ip)
5. [Control plane vs user plane](#5-control-plane-vs-user-plane)
6. [LTE attach walkthrough on your 2 PCs](#6-lte-attach-walkthrough-on-your-2-pcs)
7. [What is IMS and why it sits on top of LTE](#7-what-is-ims-and-why-it-sits-on-top-of-lte)
8. [How EPC and IMS are connected](#8-how-epc-and-ims-are-connected)
9. [IMS registration path (SIP + Diameter)](#9-ims-registration-path-sip--diameter)
10. [Databases in your lab — who stores what](#10-databases-in-your-lab--who-stores-what)
11. [Protocol map (what talks to what)](#11-protocol-map-what-talks-to-what)
12. [Glossary](#12-glossary)
13. [Mental models & common confusions](#13-mental-models--common-confusions)
14. [Learning checklist mapped to your lab](#14-learning-checklist-mapped-to-your-lab)

---

## 1. The big picture in plain language

Think of modern mobile voice/data as **two layers**:

```text
┌─────────────────────────────────────────────────────────┐
│  IMS  = "the phone app platform"                        │
│         SIP calls, registration, identity (phone number)│
│         Kamailio P/I/S-CSCF + pyHSS on PC-2             │
└──────────────────────────▲──────────────────────────────┘
                           │ needs an IP path first
┌──────────────────────────┴──────────────────────────────┐
│  EPC  = "the mobile ISP / tunnel factory"               │
│         authenticate SIM, give UE an IP, move packets   │
│         Open5GS MME/HSS/SGW/PGW(SMF+UPF) on PC-2        │
└──────────────────────────▲──────────────────────────────┘
                           │ needs radio + S1 first
┌──────────────────────────┴──────────────────────────────┐
│  RAN  = "the radio access"                              │
│         UE ↔ eNodeB (in your lab: ZMQ instead of SDR)   │
│         PC-1                                            │
└─────────────────────────────────────────────────────────┘
```

### One-sentence roles

| Layer | Job |
|-------|-----|
| **RAN** | Move radio/RRC/NAS messages between UE and core |
| **EPC** | Decide if the UE is allowed on the network; create IP tunnels |
| **IMS** | Once the UE has an IP path suitable for telephony, handle SIP calling |

### Your lab in one diagram

```text
PC-1 10.195.138.30                 PC-2 10.195.138.20
┌──────────────────┐               ┌────────────────────────────┐
│ srsUE            │               │ Open5GS EPC                │
│   ↕ ZMQ I/Q      │  S1AP + GTP-U │  MME HSS SGW SMF/UPF PCRF  │
│ srsENB           ├──────────────►│                            │
└──────────────────┘               │ Kamailio IMS + pyHSS + DNS │
                                   └────────────────────────────┘
```

**Key beginner insight:**  
IMS does **not** replace EPC.  
IMS **rides on** an IP connection that EPC created (usually the `ims` APN/PDN).

---

## 2. Actors in your lab

### On PC-1 (RAN + UE)

| Name | What it is | Analogy |
|------|------------|---------|
| **srsUE** | Software phone/modem | A phone without a real SIM chip (soft USIM) |
| **ZMQ** | Fake RF cable | Instead of radio waves, I/Q samples over TCP |
| **srsENB** | Software base station | Cell tower software |

### On PC-2 (core)

| Name | 3GPP role | Analogy |
|------|-----------|---------|
| **MME** | Mobility Management Entity | Reception desk + traffic cop for signalling |
| **HSS** (Open5GS) | Home Subscriber Server | SIM authentication database for LTE |
| **SGW-C / SGW-U** | Serving Gateway | Entry gateway on the “visited” side of the tunnel |
| **SMF + UPF** | In 4G mode these act as **PGW-C / PGW-U** | Anchor that assigns UE IP and exits to Internet/IMS |
| **PCRF** | Policy/charging rules | QoS / policy brain |
| **P-CSCF / I-CSCF / S-CSCF** | IMS call servers | SIP front desk / finder / registrar |
| **pyHSS** | IMS HSS | Identity + auth database for SIP/IMS |
| **DNS** | IMS/EPC name service | Finds `pcscf.ims...` hostnames |
| **MySQL** | IMS app DB | Kamailio/pyHSS persistent data |
| **MongoDB** | Open5GS DB | LTE subscriber profiles for WebUI/HSS |

You do **not** need to memorize every box on day one.  
Remember only: **MME+HSS authenticate**, **SGW+PGW move IP packets**, **CSCFs do SIP**, **pyHSS authenticates SIP**.

---

## 3. What is an APN?

### Beginner definition

An **APN (Access Point Name)** is the **name of a network service** the UE asks to join.

It is **not** an IP address.  
It is more like a **VPN profile name** or **SSID for a packet network**.

Examples in your lab:

| APN name | Purpose | UE IP pool (from `.env`) |
|----------|---------|---------------------------|
| `internet` | Normal data / browsing | `192.168.100.0/24` |
| `ims` | Telephony signalling/media path toward IMS | `192.168.101.0/24` |

### Why APNs exist

The operator wants different services on different paths:

* Internet traffic → NAT to the public Internet
* IMS traffic → route to P-CSCF **without** breaking SIP (often no NAT toward P-CSCF)

In Open5GS/docker_open5gs, SMF/UPF are configured with two DNNs/APNs:

* `internet` on `ogstun`
* `ims` on `ogstun2`

### What the UE configures

In `srslte/ue_zmq.conf`:

```ini
[nas]
apn = internet
apn_protocol = ipv4
```

That means: “During attach / PDN connect, ask for the **internet** service.”

### What must match

| Place | Must agree |
|-------|------------|
| UE `apn = internet` | Open5GS subscriber has APN `internet` |
| Open5GS APN `ims` | SMF/UPF have `dnn: ims` |
| pyHSS APN list | Includes internet + ims for IMS-capable UEs |

If the UE asks for an APN the HSS subscriber profile does not allow, PDN setup fails.

---

## 4. PDN / PDU sessions — how the UE gets an IP

### Vocabulary (4G vs 5G)

| Term | Generation | Meaning |
|------|------------|---------|
| **PDN connection** | 4G/LTE | Packet Data Network connection (your lab) |
| **PDU session** | 5G | Same idea, newer name |

Your lab is **4G**, so say **PDN**.

### What “getting an IP” really means

The UE does **not** run classic DHCP on Wi-Fi.  
In LTE, the **core network assigns** an IP during PDN connectivity setup and tells the UE in NAS signalling.

Simplified sequence:

```text
1) UE authenticates (Attach)
2) UE (or network) requests a PDN connection for an APN
3) MME asks SGW/PGW (SMF/UPF in Open5GS) to create a session
4) PGW/UPF picks an IP from the APN pool
5) That IP is returned to the UE in NAS
6) UE creates a TUN interface (e.g. tun_srsue) with that IP
```

### In your lab numbers

| Stage | Example value |
|-------|---------------|
| APN requested | `internet` |
| Pool on PC-2 | `192.168.100.0/24` |
| UE might get | `192.168.100.2` (example; exact host varies) |
| Gateway inside UPF | first usable address in that pool |

For IMS later:

| Stage | Example value |
|-------|---------------|
| APN | `ims` |
| Pool | `192.168.101.0/24` |
| P-CSCF address pushed | `172.22.0.21` (`PCSCF_IP`) via protocol config options |

### Important: one UE can have multiple PDNs

A commercial VoLTE phone typically has:

1. **internet** PDN → browsing, apps  
2. **ims** PDN → SIP REGISTER / calls  

srsUE in the default repo config mainly demonstrates the **internet** PDN.  
That is why attach + ping work first, while full VoLTE needs extra IMS client/PDN understanding.

### Bearer (quick idea)

When a PDN is created, the network also creates **bearers** (pipes with QoS):

* **Default bearer** — always-on pipe for that PDN (e.g. QCI 9 for internet, QCI 5 for IMS signalling)
* **Dedicated bearers** — extra pipes for voice media (e.g. QCI 1)

You can ignore dedicated bearers until voice media works.

---

## 5. Control plane vs user plane

This is the #1 concept that makes EPC less scary.

### Control plane = “conversation about the connection”

Examples:

* Attach Request / Accept  
* Authentication  
* PDN Connectivity Request  
* S1 Setup between eNB and MME  

In your lab:

```text
UE --(RRC/NAS over ZMQ radio)-- eNB --(S1AP/SCTP)-- MME --(Diameter)-- HSS
```

S1AP uses **SCTP** to PC-2 host port **36412**.

### User plane = “the actual IP packets”

Examples:

* ping 8.8.8.8  
* HTTP  
* SIP REGISTER bytes  
* RTP voice media  

In your lab:

```text
UE TUN -- eNB --(GTP-U/UDP)-- SGWU -- UPF/ogstun -- Internet or P-CSCF
```

GTP-U uses **UDP port 2152** to PC-2 host (because `SGWU_ADVERTISE_IP=10.195.138.20`).

### Memory hook

| If you are debugging… | Look at… |
|-----------------------|----------|
| “UE won’t attach / auth fail” | Control plane: MME/HSS/NAS |
| “Attached but ping fails” | User plane: SGWU advertise IP, GTP-U, UPF NAT |
| “Data works, SIP fails” | IMS path / P-CSCF / DNS / pyHSS |

---

## 6. LTE attach walkthrough on your 2 PCs

### Step A — Radio (PC-1 only)

```text
srsUE ◄── ZMQ tcp://10.195.138.30:2000/2001 ──► srsENB
```

No EPC involved yet. If ZMQ is wrong, nothing else matters.

### Step B — eNB joins the core (S1 Setup)

```text
srsENB (10.195.138.30) --SCTP/S1AP--> 10.195.138.20:36412 --> MME container
```

Meaning: the cell tower registers to the MME.  
Until this works, the UE can camp on a cell but cannot attach to the operator network.

### Step C — UE identity + authentication

1. UE sends IMSI (or GUTI) in Attach.
2. MME asks Open5GS **HSS** for authentication vectors.
3. HSS uses subscriber **K** and **OPc/OP** (MILENAGE) to build a challenge.
4. UE USIM (soft SIM in srsUE) answers using the same K/OP.
5. If answers match → UE is trusted.

**Your matching secrets (example from the setup README):**

| Field | Value |
|-------|-------|
| IMSI | `001011234567895` |
| K | `8baf473f2f8fd09487cccbd7097c6862` |
| OP (UE side) | `11111111111111111111111111111111` |
| OPc (HSS/pyHSS side) | `8e27b6af0e692e750f32667a3b14605d` |

Beginner warning: **OP and OPc are related, not interchangeable labels for the same box.**  
If UE uses OP and HSS expects OPc, they must be the matching pair for the same K.

### Step D — Create default PDN (get IP)

1. Network creates session toward SGW/PGW.
2. UPF allocates `192.168.100.x` for APN `internet`.
3. UE configures TUN with that IP.
4. eNB creates GTP-U tunnel toward advertised SGWU address `10.195.138.20`.

### Step E — Browse / ping

UE packet → eNB → GTP-U to PC-2 → SGWU → UPF `ogstun` → NAT → Internet.

If attach succeeded but ping failed, your control plane is OK and user plane is broken (classic multihost symptom when `SGWU_ADVERTISE_IP` is still a Docker IP).

---

## 7. What is IMS and why it sits on top of LTE

### Beginner definition

**IMS (IP Multimedia Subsystem)** is the operator’s **SIP-based telephony platform**.

VoLTE means:

> Voice is no longer circuit-switched like old 2G/3G calls.  
> Voice is a **SIP application** running over **IP bearers created by EPC**.

### Why not just “SIP over the internet APN”?

srsUE in this lab should request **`internet` only**. Setting the UE NAS APN to **`ims`** usually **disconnects** the software UE (single PDN, QCI 5, PCRF). Use Asterisk for a desk-phone call over `tun_srsue`, or Kamailio for IMS AKA — [`README_IMS_APN_DISCONNECT_AND_ASTERISK.md`](./README_IMS_APN_DISCONNECT_AND_ASTERISK.md).

You *can* run a softphone over `internet`, but operators use a dedicated **ims** APN because they need:

* known QoS (signalling QCI 5, voice QCI 1)
* trusted path to P-CSCF
* policy control (PCRF / Rx or equivalent)
* lawful intercept / charging hooks
* stable discovery of P-CSCF

### IMS identities (do not confuse with IMSI alone)

| Identity | Example | Meaning |
|----------|---------|---------|
| **IMSI** | `001011234567895` | SIM identity for radio/EPC auth |
| **IMPI** (private) | `001011234567895@ims.mnc001.mcc001.3gppnetwork.org` | IMS login username |
| **IMPU** (public) | `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org` | Dialable public identity |
| **MSISDN** | `9076543210` | “Phone number” style identity |

EPC cares first about **IMSI + K**.  
IMS cares about **IMPI/IMPU + IMS auth keys in pyHSS** (usually same Ki/OPc material).

---

## 8. How EPC and IMS are connected

They are connected in **three practical ways** in your docker_open5gs lab.

### Connection 1 — IP path (mandatory)

```text
UE (ims PDN IP 192.168.101.x)
  → eNB → SGWU → UPF (ogstun2, no NAT toward P-CSCF)
  → P-CSCF 172.22.0.21:5060
```

Without a working user-plane path to P-CSCF, SIP never starts.

### Connection 2 — P-CSCF discovery via EPC (very important)

In `smf/smf_4g.yaml`, SMF is configured with:

```yaml
p-cscf:
  - PCSCF_IP
```

During PDN setup, the EPC can send the **P-CSCF IP** to the UE in protocol configuration options (PCO).  
So the UE does not always need DNS to find P-CSCF.

That is one of the cleanest “EPC helps IMS” integrations.

### Connection 3 — Policy signalling (Rx / PCRF)

For VoLTE QoS, P-CSCF can talk to **PCRF** (Rx interface) so the EPC creates dedicated voice bearers when a call starts.

In `4g-volte-deploy.yaml`, P-CSCF runs with `DEPLOY_MODE=4G`, which keeps the Rx-oriented path enabled in the repo’s init logic.

You can learn SIP REGISTER first and treat Rx/dedicated bearers as the next layer.

### What is *not* a direct cable

There is usually **no** “MME talks SIP to S-CSCF” link.  
MME does LTE mobility. CSCFs do SIP. They meet through the **UE’s IP session** and through **policy/HSS ecosystems**.

```text
        Diameter (Cx)
 pyHSS ◄─────────────► I-CSCF / S-CSCF

        Diameter (LTE auth)
 Open5GS HSS ◄────────► MME

        IP + SIP
 UE ◄──EPC tunnels──► P-CSCF → I-CSCF → S-CSCF
```

Two HSS-like systems appear in this repo on purpose:

* **Open5GS HSS** → LTE attach auth  
* **pyHSS** → IMS Cx auth  

Beginners often provision only one and then wonder why SIP fails.

---

## 9. IMS registration path (SIP + Diameter)

### Happy-path REGISTER

```text
UE SIP REGISTER
   → P-CSCF   (first contact; topology hiding / security)
   → I-CSCF   (asks HSS who should serve this user)
   → S-CSCF   (registers the user; challenges auth)
        ⇅ Diameter Cx
      pyHSS   (stores IMS subscription + auth vectors)
   ← 200 OK REGISTER
```

### What each CSCF does (store this)

| CSCF | Name | Job in one line |
|------|------|-----------------|
| **P-CSCF** | Proxy | UE’s SIP gateway into the operator |
| **I-CSCF** | Interrogating | Finds the right S-CSCF using HSS |
| **S-CSCF** | Serving | The user’s registrar / session brain |

### DNS role

Inside PC-2 Docker network, names like:

```text
pcscf.ims.mnc001.mcc001.3gppnetwork.org
icscf.ims.mnc001.mcc001.3gppnetwork.org
scscf.ims.mnc001.mcc001.3gppnetwork.org
```

resolve via the `dns` container (`172.22.0.15`) to the Kamailio container IPs.

### Why REGISTER often shows 401 first

Normal IMS/SIP digest or AKA auth flow:

1. First REGISTER (no credentials) → **401 Unauthorized** + challenge  
2. Second REGISTER (with response) → **200 OK**

Seeing `401` once is often **success-in-progress**, not failure.

---

## 10. Databases in your lab — who stores what

This is where many learners get lost.

### MongoDB (Open5GS)

| Stores | Used by | You edit via |
|--------|---------|--------------|
| IMSI, K/OPc, AMF, APN list, AMBR, MSISDN | Open5GS HSS / WebUI | WebUI `:9999` or `open5gs-dbctl` |

If Mongo subscriber is wrong → **LTE attach/auth fails**.

### MySQL

| Stores | Used by | You edit via |
|--------|---------|--------------|
| Kamailio IMS tables, pyHSS relational data | `pcscf`/`icscf`/`scscf`/`pyhss` | mostly auto-init + pyHSS API `:8080` |

If pyHSS IMS subscriber is missing → **SIP REGISTER fails** even if LTE works.

### OsmoHLR (separate small DB/process)

Used for SMS-over-SGs pieces in this compose stack (IMSI↔MSISDN).  
Not your main VoLTE brain, but the setup README provisions it for completeness.

### Mental model

```text
Want LTE attach?     → provision Open5GS (Mongo)
Want IMS REGISTER?   → ALSO provision pyHSS (MySQL/API)
Want matching phone# → MSISDN aligned in both worlds
```

### Same subscriber, two provisioning acts

For IMSI `001011234567895`:

1. Open5GS: allow attach + APNs `internet`/`ims`  
2. pyHSS: AUC + subscriber + ims_subscriber with IMPU/MSISDN  

Skipping #2 is the classic “data works, VoLTE dead” lab state.

---

## 11. Protocol map (what talks to what)

### On the wire between your PCs

| Protocol | From → To | Purpose |
|----------|-----------|---------|
| **ZMQ/TCP** | UE ↔ eNB on PC-1 | Fake RF |
| **SCTP + S1AP** | eNB → MME (`10.195.138.20:36412`) | RAN control plane |
| **UDP + GTP-U** | eNB ↔ SGWU (`:2152`) | User plane tunnel |

### Inside PC-2 Docker network (`172.22.0.0/24`)

| Protocol | Path | Purpose |
|----------|------|---------|
| **Diameter (S6a)** | MME ↔ Open5GS HSS | LTE auth/location |
| **GTP-C / PFCP** | MME/SGW/SMF/UPF internals | Create/modify sessions |
| **Diameter (Gx)** | SMF/PGW ↔ PCRF | Policy |
| **SIP** | UE → P-CSCF → I-CSCF → S-CSCF | IMS signalling |
| **Diameter (Cx)** | I/S-CSCF ↔ pyHSS | IMS auth/user data |
| **DNS** | IMS components → `dns` | Resolve IMS hostnames |
| **RTP** (later) | UE ↔ RTPEngine path | Voice media |

### Why Docker IPs confuse beginners

Inside PC-2, MME is `172.22.0.9`.  
From PC-1, you must use **`10.195.138.20`** because only the host ports are published.

Rule:

> **Same PC / same Docker network → container IPs are fine.**  
> **Other physical PC → use LAN IP + published ports / advertise IPs.**

---

## 12. Glossary

| Term | Simple meaning |
|------|----------------|
| **UE** | User Equipment (phone/modem) |
| **eNB / eNodeB** | 4G base station |
| **EPC** | 4G core network |
| **IMS** | SIP telephony core |
| **IMSI** | Permanent subscriber ID on SIM |
| **MSISDN** | Phone number |
| **APN** | Named packet network profile (`internet`, `ims`) |
| **DNN** | 5G name for APN-like network name (Open5GS config uses DNN too) |
| **PDN** | The actual IP session created for an APN |
| **Bearer** | QoS pipe inside/alongside a PDN |
| **TUN** | Virtual network interface on UE holding the PDN IP |
| **NAS** | Signalling between UE and MME |
| **S1AP** | Signalling between eNB and MME |
| **GTP-U** | Tunnel that carries user IP packets over the backhaul |
| **PCO** | Extra options during PDN setup (can include P-CSCF, DNS) |
| **P/I/S-CSCF** | IMS SIP servers with different jobs |
| **HSS** | Subscriber database / auth center |
| **MILENAGE** | Algo family using K + OP/OPc for auth |
| **VoLTE** | Voice over LTE = IMS voice using LTE bearers |
| **ZMQ** | Your lab’s stand-in for radio hardware |

---

## 13. Mental models & common confusions

### Confusion 1 — “IMS IP” vs “Internet IP”

The UE can have **two** addresses:

* `192.168.100.x` on `internet`  
* `192.168.101.x` on `ims`  

Ping Google uses the first.  
SIP REGISTER preferably uses the second (operator model).

### Confusion 2 — “HSS” singular

In this lab there are effectively **two subscriber worlds**:

* Open5GS HSS for radio attach  
* pyHSS for IMS  

Both must know your user for full VoLTE.

### Confusion 3 — Docker IP vs LAN IP

| Address | Reachable from PC-1? |
|---------|----------------------|
| `172.22.0.9` (MME) | No (normally) |
| `10.195.138.20:36412` | Yes (published) |
| `172.22.0.6` (SGWU) | No (normally) |
| `10.195.138.20:2152` | Yes if advertised/published correctly |

### Confusion 4 — APN vs IP

* APN = **which service**  
* PDN IP = **address assigned after joining that service**

### Confusion 5 — 401 on SIP

Often normal challenge. Failure is repeated 401/403/timeout with no final 200 OK.

### Confusion 6 — “EPC and IMS integration” means one magic protocol

It usually means a **bundle**:

1. shared subscriber identity planning (IMSI/MSISDN)  
2. IMS APN/PDN  
3. P-CSCF address delivery  
4. optional PCRF policy for voice bearers  
5. DNS for IMS hostnames  

---

## 14. Learning checklist mapped to your lab

Use this as a study path. Check boxes only when you can explain *and* demonstrate.

### Level 0 — Lab plumbing

- [ ] I can ping `10.195.138.20` ↔ `10.195.138.30`
- [ ] I can explain why eNB uses `MME_IP=10.195.138.20`, not `172.22.0.9`
- [ ] I can explain why `SGWU_ADVERTISE_IP` must be the PC-2 LAN IP

### Level 1 — RAN

- [ ] I know ZMQ replaces SDR in this lab
- [ ] I can start eNB then UE in the correct order
- [ ] I understand S1 Setup is eNB↔MME, before UE attach

### Level 2 — EPC attach

- [ ] I can explain IMSI/K/OP-OPc matching
- [ ] I can provision Open5GS subscriber in WebUI
- [ ] I can point to MME/HSS logs during auth
- [ ] I can show the UE got `192.168.100.x`

### Level 3 — User plane

- [ ] I can explain GTP-U in one sentence
- [ ] I can capture UDP/2152 between the two PCs
- [ ] I can ping Internet from the UE namespace
- [ ] I can say whether a failure is control-plane or user-plane

### Level 4 — APN / PDN mental model

- [ ] I can define APN without saying “IP address”
- [ ] I can define PDN as “the session that gives me an IP for an APN”
- [ ] I know `internet` and `ims` are different services/pools

### Level 5 — IMS foundations

- [ ] I can draw P-CSCF → I-CSCF → S-CSCF
- [ ] I know Open5GS HSS ≠ pyHSS
- [ ] I can provision pyHSS AUC + IMS subscriber
- [ ] I understand P-CSCF IP can come from EPC PCO

### Level 6 — Integration

- [ ] I can explain three EPC↔IMS connections: IP path, P-CSCF discovery, policy/Rx
- [ ] I can list which DB to fix for attach vs REGISTER failures
- [ ] I can watch SIP with `sngrep` and Diameter with `tcpdump`

---

## Suggested study order with your machines

1. **PC-2 up only** — learn container roles (`docker compose ps`, WebUI, pyHSS docs).  
2. **S1 only** — bring eNB on PC-1; stop when S1 is UP.  
3. **Attach + IP** — bring UE; confirm `192.168.100.x`.  
4. **User plane** — ping; tcpdump GTP-U.  
5. **APN theory** — re-read Sections 3–4 with your actual pools.  
6. **IMS theory** — Sections 7–10 before any softphone.  
7. **REGISTER** — only after LTE data is boringly reliable.

---

## Relationship to the other guides

| File | Purpose |
|------|---------|
| [`README.md`](./README.md) | Build/run/configure the 2-PC lab (commands, file edits, troubleshooting) |
| [`README_UE_JOURNEY_LTE_IMS.md`](./README_UE_JOURNEY_LTE_IMS.md) | Absolute-beginner story: one UE journey across PC-1 and PC-2 |
| **This file** | Teach the telecom meaning behind those steps (concept reference)

When `README.md` says “set `SGWU_ADVERTISE_IP=10.195.138.20`”, this file is where you learn **why**: because the eNB must send user-plane GTP-U to an address it can reach on the LAN, not to a Docker-internal IP on the other PC.

---

## Tiny cheat sheet (print this)

```text
APN     = which service name I request (internet / ims)
PDN     = the IP session I get for that APN
EPC     = authenticates me + builds tunnels + assigns IP
IMS     = SIP telephony once I have a suitable IP path
Open5GS HSS (Mongo) = LTE secrets
pyHSS (MySQL/API)   = IMS secrets
S1AP/SCTP :36412    = control plane PC-1 → PC-2
GTP-U/UDP :2152     = user plane PC-1 ↔ PC-2
P-CSCF              = my SIP door into IMS
```

You do not need to master everything before the first attach.  
Master **attach + IP + ping** first. Everything in IMS becomes much easier after that feels obvious.

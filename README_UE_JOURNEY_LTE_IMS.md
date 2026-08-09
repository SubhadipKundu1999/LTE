# Absolute Beginner Story: One UE Journey Across Your 2-PC Lab

**Follow one phone from cold start → LTE IP → IMS registration**, using your real machines.

| Machine | Role | LAN IP |
|---------|------|--------|
| **PC-1** | srsUE + ZMQ eNodeB | `10.195.138.30` |
| **PC-2** | Open5GS EPC + Kamailio IMS | `10.195.138.20` |

This file is a **story walkthrough**.  
It deliberately goes slower than the concept reference guide.

| File | When to use it |
|------|----------------|
| **This file** | “Tell me what happens, in order, like I’m new” |
| [`README_BEGINNER_LTE_EPC_IMS.md`](./README_BEGINNER_LTE_EPC_IMS.md) | Concept lookup (APN, PDN, DBs, protocols) |
| [`README.md`](./README.md) | Exact commands, configs, troubleshooting |

---

## How to read this

1. Read **Chapters 0–3** before you start anything.  
2. Read **Chapters 4–6** while doing first attach + ping.  
3. Read **Chapters 7–9** only after data works.  
4. Use the **self-check** at the end of each chapter — answer out loud.

Goal after this document:

> You can narrate, without notes, what happens on PC-1 and PC-2 from power-on to SIP REGISTER, and you know which database / protocol each failure belongs to.

---

## Chapter 0 — The one analogy that carries everything

Imagine a city with three departments:

```text
RADIO STREET (PC-1)
  = the road + the checkpoint booth between phone and city

MOBILE ISP OFFICE (EPC on PC-2)
  = checks your SIM, opens a private tunnel, gives you an IP address

PHONE APP HEADQUARTERS (IMS on PC-2)
  = once you have the right IP tunnel, handles “login as phone number” and calls (SIP)
```

Critical beginner truth:

> **IMS cannot help you until EPC has already given you a usable IP path.**  
> Voice over LTE is not a separate radio network. It is an **app** riding on an **IP session**.

In your lab that means:

1. PC-1 brings up fake radio (ZMQ) and a software cell tower.  
2. PC-2 authenticates the SIM and creates tunnels.  
3. Only then can SIP talk to Kamailio / pyHSS.

---

## Chapter 1 — What is physically on each PC?

### PC-1 (`10.195.138.30`) — “the handset + the tower”

| Process | Pretends to be | Lives where |
|---------|----------------|-------------|
| **srsUE** | Your phone/modem | PC-1 |
| **ZMQ** | The radio waves (fake RF cable) | PC-1 only |
| **srsENB** | The cell tower | PC-1 |

Nothing about APN, HSS, or SIP happens *inside* ZMQ.  
ZMQ only moves I/Q samples between UE and eNB on the same PC:

```text
srsUE  ←tcp://10.195.138.30:2000/2001→  srsENB
```

### PC-2 (`10.195.138.20`) — “the operator core”

Two big worlds share this one machine (usually via Docker Compose):

| World | Job | Main boxes |
|-------|-----|------------|
| **EPC** | SIM auth + IP tunnels | MME, Open5GS HSS, SGW, SMF/UPF (PGW), PCRF, MongoDB |
| **IMS** | SIP identity + calls | P-CSCF, I-CSCF, S-CSCF, pyHSS, DNS, MySQL |

Beginner memory hook:

```text
PC-1 = radio side
PC-2 = everything “operator”
```

### Self-check

1. If ZMQ ports are wrong, which PC is broken?  
2. If SIP REGISTER fails but ping works, which *world* on PC-2 do you suspect first?

Answers: (1) PC-1. (2) IMS world (or the IMS PDN path), not ZMQ.

---

## Chapter 2 — Words you must stop mixing up

Say these out loud with the lab meanings.

### APN = the *name of the service* you ask for

Not an IP.  
More like choosing a VPN profile name.

In your lab:

| APN | Meaning | Typical UE IP pool |
|-----|---------|--------------------|
| `internet` | Normal data | `192.168.100.0/24` |
| `ims` | Telephony path toward IMS | `192.168.101.0/24` |

### PDN = the *actual session* you get after asking for an APN

4G says **PDN connection**.  
5G renamed the idea to **PDU session**. Your lab is 4G → say **PDN**.

```text
APN request  →  “I want the internet service”
PDN result   →  “OK, here is IP 192.168.100.2 and a tunnel”
```

### How the UE gets an IP (not Wi-Fi DHCP)

1. UE authenticates with the core (Attach).  
2. Network creates a PDN for the requested APN.  
3. PGW/UPF picks an address from that APN’s pool.  
4. That address is delivered to the UE in **NAS signalling**.  
5. srsUE creates a TUN interface (for example `tun_srsue`) with that IP.

There is usually **no classic DHCP discover** on the LTE path in this lab model.

### Self-check

Fill blanks:

* APN answers “____ service?”  
* PDN answers “what ____ and tunnel do I have?”  
* The box that typically assigns the UE IP is the ____ / UPF side.

Answers: which / IP / PGW.

---

## Chapter 3 — Control plane vs user plane (your debugging superpower)

### Control plane = talking *about* the connection

Examples:

* eNB ↔ MME: “I am a cell tower; S1 Setup”  
* UE ↔ MME: “Attach me; here is my IMSI”  
* MME ↔ HSS: “Give me auth vectors for this IMSI”

In your 2-PC lab, the important LAN control link is:

```text
srsENB (10.195.138.30)
   -- SCTP / S1AP -->
10.195.138.20:36412   (published into MME on PC-2)
```

### User plane = the actual payload packets

Examples:

* `ping 8.8.8.8`  
* HTTP  
* SIP REGISTER bytes  
* later: RTP voice

LAN user-plane link:

```text
srsENB (10.195.138.30)
   -- UDP / GTP-U -->
10.195.138.20:2152    (published/advertised SGWU on PC-2)
```

### Why beginners get stuck on multihost labs

Inside Docker on PC-2, MME may be `172.22.0.9` and SGWU `172.22.0.6`.  
**PC-1 cannot use those addresses.**

| Address | From PC-1? |
|---------|------------|
| `172.22.0.9` | No |
| `10.195.138.20:36412` | Yes (S1AP) |
| `172.22.0.6` | No |
| `10.195.138.20:2152` | Yes (GTP-U), if advertise/publish is correct |

Rule carved in stone for your lab:

> **Same Docker network → container IPs OK.**  
> **Other physical PC → LAN IP + published/advertised ports.**

### Self-check

Symptom → plane?

| Symptom | Plane |
|---------|-------|
| Attach rejected / auth fail | ? |
| Attached, IP present, ping fails | ? |
| Ping works, SIP fails | ? |

Answers: control / user / IMS (or IMS user-path), not “radio is dead”.

---

## Chapter 4 — Story start: fake radio, then the tower joins the core

### Scene 1 — Only PC-1 matters

```text
You start srsENB, then srsUE.
They exchange ZMQ samples on 10.195.138.30:2000/2001.
The UE can “see a cell”.
```

If this fails, stop. EPC cannot fix a broken fake radio.

### Scene 2 — The tower phones the operator (S1 Setup)

```text
srsENB on PC-1 opens SCTP to 10.195.138.20:36412
MME on PC-2 accepts S1 Setup
```

Meaning in plain language:

> The cell tower is now connected to the operator’s control desk (MME).

Until S1 is up, the UE may camp on a cell but cannot attach to the network.

### What you should feel after Chapter 4

* ZMQ = local on PC-1  
* S1 = PC-1 → PC-2 control plane  
* Still no UE IP yet

---

## Chapter 5 — Attach: “prove you are this SIM”

Now the UE asks to join the network.

### Cast

| Actor | On which PC | Job now |
|-------|-------------|---------|
| srsUE | PC-1 | Sends Attach with IMSI (or GUTI) |
| srsENB | PC-1 | Forwards NAS to MME over S1AP |
| MME | PC-2 | Runs the attach procedure |
| Open5GS HSS + MongoDB | PC-2 | Holds LTE subscriber secrets |

### Auth in one breath

```text
1) MME asks HSS: “auth vectors for IMSI 001011234567895?”
2) HSS uses K + OPc (MILENAGE) → challenge
3) Challenge goes to UE
4) Soft USIM in srsUE answers using matching K + OP
5) Answers match → UE is trusted
```

Example secrets used in the setup tutorial (must match as a *pair*):

| Field | Example |
|-------|---------|
| IMSI | `001011234567895` |
| K | `8baf473f2f8fd09487cccbd7097c6862` |
| OP on UE | `11111111111111111111111111111111` |
| OPc in HSS | `8e27b6af0e692e750f32667a3b14605d` |

Beginner trap: **OP and OPc are related, not two names for the same value in the same box.**

### After auth succeeds

The network creates the **default PDN** for the configured APN (often `internet`).

```text
UPF allocates something like 192.168.100.2
UE learns that IP via NAS
UE brings up TUN with 192.168.100.2
eNB builds GTP-U toward advertised SGWU = 10.195.138.20
```

### Self-check

If WebUI/Mongo subscriber is missing or K is wrong, what fails first: ping or attach?  
Answer: **attach / auth** (control plane).

---

## Chapter 6 — First victory: packets leave the phone

### Path of a ping to the Internet

```text
App/ping on UE
  → UE TUN (192.168.100.x)
  → srsUE stack
  → ZMQ to srsENB          (still PC-1)
  → GTP-U UDP/2152         to 10.195.138.20
  → SGWU → UPF (ogstun)
  → NAT / routing on PC-2
  → Internet
```

If attach worked but ping failed, classic cause in *this* lab:

> `SGWU_ADVERTISE_IP` still points at a Docker IP (`172.22.0.6`) instead of PC-2 LAN (`10.195.138.20`).  
> Control plane reached MME; user plane has nowhere reachable to land.

### What “success” looks like conceptually

* UE has an IP in `192.168.100.0/24`  
* S1AP and GTP-U between PCs are healthy  
* You can explain control vs user plane without looking it up

Do **not** rush to IMS before this is boringly reliable.

---

## Chapter 7 — Why IMS exists (and why it rides on EPC)

### Old mental model (2G/3G style)

Voice was a special circuit path.  
Data was something else.

### LTE + VoLTE mental model

```text
EPC builds IP pipes.
IMS is the SIP telephone application platform that uses those pipes.
```

So:

* **EPC** = “mobile ISP / tunnel factory”  
* **IMS** = “operator SIP calling system”

### Why operators use an `ims` APN instead of only `internet`

You *could* point a softphone at P-CSCF over the internet APN in a lab toy.  
Operators usually want a dedicated IMS PDN because they need:

* predictable QoS (signalling vs voice media)  
* a trusted path to P-CSCF  
* policy control (PCRF / Rx ideas)  
* clean discovery of P-CSCF  
* charging / intercept hooks

In your pools:

| APN | Pool | Typical use |
|-----|------|-------------|
| `internet` | `192.168.100.0/24` | browsing / general data |
| `ims` | `192.168.101.0/24` | SIP toward P-CSCF |

### Identities (do not smash them together)

| Identity | Example | Who cares first |
|----------|---------|-----------------|
| **IMSI** | `001011234567895` | EPC / radio auth |
| **IMPI** | `001011234567895@ims.mnc001.mcc001.3gppnetwork.org` | IMS private login |
| **IMPU** | `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org` | public SIP identity |
| **MSISDN** | `9076543210` | “phone number” style id |

### Self-check

True or false: “IMS replaces the MME.”  
Answer: **False.** IMS sits *above* the IP path EPC created.

---

## Chapter 8 — How EPC and IMS are actually connected in *your* lab

People search for one magic “EPC–IMS cable.”  
In practice your docker_open5gs-style lab connects them in **three** ways.

### Connection A — IP path (mandatory)

```text
UE IMS PDN IP (192.168.101.x)
  → eNB → SGWU → UPF (often ogstun2, no NAT toward P-CSCF)
  → P-CSCF 172.22.0.21:5060
```

No reachable path to P-CSCF ⇒ no SIP, period.

### Connection B — P-CSCF discovery via EPC (very important)

During PDN setup, SMF/PGW can push the P-CSCF address to the UE in **PCO** (Protocol Configuration Options).

In the repo idea:

```yaml
# smf config concept
p-cscf:
  - PCSCF_IP   # e.g. 172.22.0.21
```

So EPC actively helps the UE find IMS.

### Connection C — Policy (Rx / PCRF) for call QoS

When a call starts, P-CSCF can signal PCRF so EPC creates better bearers for voice media.  
Learn REGISTER first; treat dedicated bearers as the next layer.

### What is *not* happening

```text
MME does NOT speak SIP to S-CSCF.
```

```text
        Diameter S6a                 Diameter Cx
MME ◄──────────────► Open5GS HSS     I/S-CSCF ◄──────────► pyHSS

        IP + SIP over EPC tunnels
UE ─────────────────────────────────────────────► P-CSCF → I-CSCF → S-CSCF
```

### Two subscriber databases on purpose

| Database world | Backing store | Needed for |
|----------------|---------------|------------|
| Open5GS HSS | MongoDB | LTE attach |
| pyHSS | MySQL / API | IMS REGISTER |

Classic lab state:

> Data works, VoLTE dead → you provisioned Mongo, forgot pyHSS.

### Self-check

Name the three EPC↔IMS connections used in this lab.  
Answer: IP path to P-CSCF, P-CSCF address via PCO, policy/Rx (PCRF).

---

## Chapter 9 — SIP REGISTER story (happy path)

Assume LTE data already works and an IMS-capable path exists.

### Cast

| Box | One-line job |
|-----|--------------|
| **P-CSCF** | UE’s SIP front door |
| **I-CSCF** | Asks HSS which S-CSCF should serve this user |
| **S-CSCF** | Registrar / session brain |
| **pyHSS** | IMS subscription + auth vectors (Cx) |
| **DNS** | Resolves `pcscf...` / `icscf...` / `scscf...` names inside Docker |

### Message movie

```text
1) UE sends SIP REGISTER toward P-CSCF
2) P-CSCF forwards into IMS
3) I-CSCF queries pyHSS (Diameter Cx): who serves this user?
4) S-CSCF challenges the UE (often SIP 401 first — normal!)
5) UE sends second REGISTER with credentials
6) S-CSCF verifies with pyHSS
7) 200 OK → UE is IMS-registered
```

Beginner trap: **one 401 is often progress, not failure.**  
Failure is endless 401/403/timeout with no final 200 OK.

### Where packets live during this

SIP bytes are still **user-plane IP packets** from the EPC’s point of view.  
They travel UE → eNB → GTP-U → UPF → P-CSCF, then SIP hops among CSCFs on PC-2’s Docker network.

---

## Chapter 10 — Protocol map as a travel itinerary

### Between your two physical PCs

| Hop | Protocol | Ports / notes |
|-----|----------|---------------|
| UE ↔ eNB | ZMQ/TCP | `10.195.138.30:2000/2001` |
| eNB → MME | SCTP + S1AP | `10.195.138.20:36412` |
| eNB ↔ SGWU | UDP + GTP-U | `10.195.138.20:2152` |

### Inside PC-2

| Talk | Protocol | Why |
|------|----------|-----|
| MME ↔ Open5GS HSS | Diameter S6a | LTE auth / location |
| session create among gateways | GTP-C / PFCP family | build tunnels |
| SMF/PGW ↔ PCRF | Diameter Gx | policy |
| UE → P → I → S-CSCF | SIP | IMS signalling |
| I/S-CSCF ↔ pyHSS | Diameter Cx | IMS auth / user data |
| IMS boxes → DNS | DNS | find CSCF hostnames |
| media (later) | RTP | voice |

### Database itinerary for one subscriber

```text
Want attach?     provision Open5GS (Mongo / WebUI)
Want REGISTER?   ALSO provision pyHSS (API / MySQL world)
Want same number everywhere? align MSISDN in both stories
```

---

## Chapter 11 — One-page “movie script” you should memorize

Read this until it feels obvious.

```text
0. PC-1 ZMQ: UE and eNB can hear each other
1. PC-1→PC-2 S1AP: eNB joins MME at 10.195.138.20:36412
2. Attach: MME + Open5GS HSS authenticate IMSI with K/OP-OPc
3. PDN: UPF assigns 192.168.100.x for APN "internet"
4. GTP-U: eNB sends user packets to 10.195.138.20:2152
5. Ping works → EPC user plane is healthy
6. IMS needs a suitable IP path (often APN "ims" / 192.168.101.x)
7. EPC may tell UE the P-CSCF IP (PCO)
8. SIP REGISTER: P-CSCF → I-CSCF → S-CSCF, auth via pyHSS (Cx)
9. 401 then 200 OK is a normal REGISTER dance
10. Only then think about calls, dedicated bearers, RTP
```

---

## Chapter 12 — Failure → which layer? (pocket triage)

| What you see | First place to think |
|--------------|----------------------|
| No cell / ZMQ errors | PC-1 radio fake path |
| S1 Setup fails | PC-1→PC-2 SCTP `36412`, firewall, `MME_IP` |
| Attach auth fail | Open5GS Mongo subscriber, K/OP-OPc mismatch |
| Attach OK, no IP / PDN fail | APN name mismatch, SMF/UPF pools |
| IP OK, ping fail | `SGWU_ADVERTISE_IP`, GTP-U `2152`, UPF NAT |
| Ping OK, SIP never starts | IMS PDN / route to P-CSCF / PCO |
| SIP 401 forever / 403 | pyHSS provisioning, IMPI/IMPU, IMS keys |
| DNS weirdness inside IMS | `dns` container / IMS FQDNs on PC-2 |

---

## Final self-exam (no notes)

Answer in your own words. If stuck, re-read the matching chapter.

1. What is an APN, without using the words “IP address”?  
2. What is a PDN, in one sentence?  
3. How does the UE learn its IP in this lab model?  
4. Why must `MME_IP` on PC-1 be `10.195.138.20` instead of `172.22.0.9`?  
5. Why must `SGWU_ADVERTISE_IP` be the PC-2 LAN IP?  
6. Draw (ASCII is fine) RAN → EPC → IMS.  
7. Name three ways EPC and IMS connect in this lab.  
8. Which DB do you fix for attach failure? For REGISTER failure?  
9. Why is a single SIP 401 often OK?  
10. True/False: IMS replaces EPC for VoLTE.

### Short answer key

1. Named packet-network / service profile the UE requests.  
2. The actual IP session created for that APN.  
3. Core assigns it during PDN setup and delivers it in NAS; UE configures TUN.  
4. Docker IPs on PC-2 are not reachable from PC-1; use published host ports.  
5. So eNB can send GTP-U to an address it can reach on the LAN.  
6. UE/eNB (PC-1) → MME/SGW/PGW (PC-2) → IP path → P/I/S-CSCF + pyHSS.  
7. IP path to P-CSCF; P-CSCF via PCO; policy/Rx with PCRF.  
8. Open5GS/Mongo; pyHSS/MySQL-API.  
9. Challenge-response auth: first REGISTER gets challenge, second succeeds.  
10. False.

---

## Suggested hands-on order (map story → lab)

1. Ping PC-1 ↔ PC-2.  
2. Bring up EPC/IMS stack on PC-2 only; browse WebUI / container list.  
3. Start eNB on PC-1; stop when S1 is UP.  
4. Start UE; confirm attach + `192.168.100.x`.  
5. Ping Internet; tcpdump UDP/2152 between PCs.  
6. Re-read Chapters 7–9.  
7. Provision pyHSS; attempt IMS REGISTER only after data is dull.

Commands and file edits live in [`README.md`](./README.md).  
Deeper concept tables live in [`README_BEGINNER_LTE_EPC_IMS.md`](./README_BEGINNER_LTE_EPC_IMS.md).

---

## Tiny printable card

```text
PC-1 10.195.138.30 = UE + eNB + ZMQ
PC-2 10.195.138.20 = EPC + IMS

APN  = which service name I ask for
PDN  = the IP session I get for that name
EPC  = SIM auth + tunnels + IP assignment
IMS  = SIP calling once an IP path exists

S1AP/SCTP :36412 = control plane between PCs
GTP-U/UDP :2152  = user plane between PCs

Mongo/Open5GS HSS = LTE secrets
pyHSS             = IMS secrets
P-CSCF            = SIP door into IMS
```

Master the story through **ping**.  
Only then let SIP enter the plot.

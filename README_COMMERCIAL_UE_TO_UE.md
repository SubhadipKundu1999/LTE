# UE-to-UE: what it proves (and what “commercial ready” is not)

**Question:** Can we treat the LTE lab as **commercially ready** if two UEs can communicate?

**Answer:** UE-to-UE is the **right lab gate** for “does this core actually carry subscriber traffic between phones?” It is **not** enough to call the system commercial or production VoLTE.

SIP phones on the LAN **do not count** for this gate. Only two **LTE-attached** UEs exchanging packets through Open5GS (and, for voice, through Kamailio IMS on the UE tunnels).

Full IMS client setup: [`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md).  
One-UE attach/ping: [`README.md`](./README.md).

---

## 1. Verdict for this project

| Claim | True? |
|-------|--------|
| One srsUE attach + ping 8.8.8.8 means commercial LTE | **No.** That only proves one modem got Internet NAT. |
| Two SIP phones through Kamailio means commercial VoLTE | **No.** That proves IMS signalling on the LAN, not LTE. |
| Two LTE UEs ping each other through the EPC | **Lab-ready user plane** (necessary). |
| Two LTE UEs complete a voice call through IMS **on the UE tunnels** | **Lab-ready VoLTE path** (necessary). |
| Either of the above means you can sell/operate a public network | **No.** See section 5. |

This repository is a **two-PC functional 4G + IMS prototype** (ZMQ radio, Docker Open5GS, Kamailio). Treat it as a **proof of architecture**, not a carrier product.

---

## 2. The only UE-to-UE tests that matter

Use these two gates in order. Do not skip Gate 1.

```text
Gate 1 — LTE data UE ↔ UE
  UE-1 IP  --GTP-U--  UPF  --GTP-U--  UE-2 IP
  Proof: ping / iperf between 192.168.100.x addresses

Gate 2 — VoLTE-shaped voice UE ↔ UE
  Same as Gate 1, plus SIP/RTP on the UE path (ims or internet PDN)
  Proof: REGISTER from each UE path, INVITE, two-way audio
```

```text
UE-1 (PC-1)                         PC-2                         UE-2 (PC-3)
srsUE + srsENB                      Open5GS UPF
192.168.100.2 --S1/GTP--> SGWU --> ogstun --> SGWU --S1/GTP--> 192.168.100.3
                                      |
                                      +--> Kamailio P-CSCF (Gate 2 only)
```

**Does not count as UE-to-UE**

* Ping from srsUE to `8.8.8.8` (Internet, not another UE)
* Linphone on PC-3/PC-4 to `10.195.138.20:5060` (LAN SIP, not LTE)
* Two SIP phones through Asterisk

---

## 3. Gate 1 — two LTE UEs, IP communication

You need **two attached modems**. One ZMQ eNB+UE on PC-1 cannot be a second UE on another PC over the same ZMQ pair.

### 3.1 Lab layout

| Machine | Role |
|---------|------|
| PC-2 `10.195.138.20` | Open5GS + IMS (unchanged) |
| PC-1 `10.195.138.30` | srsENB-1 + srsUE-1 (IMSI `…7895`) |
| PC-3 (spare, own LAN IP) | srsENB-2 + srsUE-2 (IMSI `…7896`) |

On PC-3: copy the PC-1 procedure in [`README.md`](./README.md). Change:

* `DOCKER_HOST_IP` / `SRS_ENB_IP` / `SRS_UE_IP` → PC-3 LAN IP  
* `MME_IP` stays `10.195.138.20`  
* `enb_id` → different value (e.g. `0x19C`)  
* USIM → second subscriber (Open5GS WebUI: IMSI, K/OP, APN `internet` + `ims`)

Both eNBs use S1AP `10.195.138.20:36412` and GTP-U `10.195.138.20:2152`.

### 3.2 Pass criteria

On each UE container, note `tun_srsue` IPv4 (`192.168.100.x`).

```bash
# On PC-1 UE container, ping UE-2's LTE IP (example)
docker exec -it srsue_zmq ping -c 5 192.168.100.3

# On PC-3, the reverse
docker exec -it srsue_zmq ping -c 5 192.168.100.2
```

**Pass:** two-way ICMP, no need for the LAN IPs `10.195.138.x`.

Optional: `iperf3` between the two TUN addresses.

On PC-2 during the ping:

```bash
sudo tcpdump -ni any udp port 2152
docker exec -it upf ping -c 2 192.168.100.2
docker exec -it upf ping -c 2 192.168.100.3
```

You should see GTP-U to **both** eNB LAN IPs.

### 3.3 If Gate 1 fails

| Symptom | Likely cause |
|---------|----------------|
| Second UE cannot attach | Subscriber not in Open5GS; duplicate `enb_id`; S1 not up on PC-3 |
| Each UE pings Internet, not each other | UPF NAT on `ogstun` rewriting intra-UE traffic; check `iptables -t nat -L -n` in `upf` |
| One-way ping | Return GTP-U blocked to the other eNB host; firewall; `SGWU_ADVERTISE_IP` not PC-2 LAN IP |

UE-to-UE on the **internet** APN should stay inside `192.168.100.0/24`. If MASQUERADE applies to that subnet, disable or exclude it for the UE pool — **verify** against `upf/upf_init.sh` on your clone. Do not NAT UE-1 into a public address when talking to UE-2.

**Pass Gate 1 before any “commercial” discussion of the data path.**

---

## 4. Gate 2 — two LTE UEs, voice

srsUE still has **no SIP stack**. After Gate 1:

1. Provision **both** IMS identities in pyHSS ([`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md)).  
2. Run an IMS client (Linphone / IMS-AKA) **using each UE’s TUN** as the path to P-CSCF (`172.22.0.21`), not the PC LAN NIC.  
3. Both REGISTER, then INVITE, two-way audio.

That is the lab equivalent of **UE-to-UE VoLTE**. SIP phones that never attach to the eNB are a Kamailio test only.

Commercial phones (programmed USIM + real RF) skip the Linphone-on-TUN hack because the handset already has the IMS client. ZMQ srsUE cannot replace that for a product trial with real devices.

---

## 5. Why Gate 1 + Gate 2 still are not “commercial”

These are normal operator/product items this Docker lab does **not** provide just because two UEs talk:

| Area | What commercial LTE/VoLTE needs |
|------|----------------------------------|
| Radio | Licensed or legally used spectrum, real eNB/gNB, coverage, interference, not ZMQ |
| Devices | Commercial UEs + operator or programmable USIMs; VoLTE IMS in the phone |
| Voice QoS | Dedicated bearer **QCI 1** (GBR) for RTP; QCI 5 for IMS signalling — not only default internet bearer |
| IMS | P-CSCF via PCO, `ims` APN, AKA, numbering, often interconnect (ENUM/BGCF) |
| Operations | HA, backups, monitoring, capacity, upgrade path |
| Business / legal | Charging/OCS, lawful intercept, emergency calling, numbering, interconnect agreements |
| Security | Hardened hosts, IPsec on S1 if required, no lab “disable UFW everywhere” |
| Identity | Production IMSI ranges (your `00101…` test PLMN is for lab) |

Passing UE-to-UE means: **this architecture can move packets (and, at Gate 2, SIP) between two subscribers.**  
It does **not** mean: **ready to offer a public or paid service.**

---

## 6. Practical meaning for your lab

If the goal is **“are we ready to show that LTE + IMS can connect two users?”**

1. Do **not** use LAN SIP phones as the proof.  
2. Bring a **second RAN PC** (PC-3) with a second srsUE.  
3. Pass **Gate 1** (UE IP ↔ UE IP).  
4. Then **Gate 2** if the demo is a phone call.  
5. For a demo with real handsets: Path C in the two-UE guide (USIM + SDR/small cell), still on this same PC-2 core.

If the goal is **“can we deploy this as a commercial network tomorrow?”**  
No — not from UE-to-UE alone. Use Gates 1–2 as **acceptance tests for the prototype**, then plan radio, USIM, QoS, HA, and regulatory work separately.

---

## 7. Short checklist

**Lab prototype (architecture proven)**

- [ ] Two different IMSIs attached at the same time  
- [ ] Two-way ping between the two `192.168.100.x` (or `192.168.101.x`) addresses  
- [ ] GTP-U visible to both eNB hosts  
- [ ] (Voice) SIP REGISTER/INVITE on those UE paths, two-way audio  

**Commercial / production (not claimed by this repo)**

- [ ] Real RF and legal spectrum use  
- [ ] Commercial UEs + production-grade SIM provisioning  
- [ ] QCI 1 dedicated bearer for voice  
- [ ] HA, charging, LI, emergency, interconnect, security review  

Gate 1 is the first thing to run with your extra PCs. Until that ping works, the setup is **not** ready to be called UE-to-UE capable, commercial or otherwise.

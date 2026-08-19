# Why `apn=ims` disconnects srsUE, and SIP via Asterisk

This lab uses **one default PDN per srsUE**. Stock `srslte/ue_zmq.conf` must keep:

```ini
[nas]
apn = internet
apn_protocol = ipv4
```

Setting `apn = ims` makes IMS the **attach PDN**. srsUE then often **RRC-releases / “disconnects”** instead of staying attached with a usable tunnel. That is expected with this RAN + Open5GS pairing, not a random RF glitch.

**srsUE is a modem, not a phone.** It has no SIP stack. A call from “srsUE” means: attach on **internet**, then run a SIP client on `tun_srsue` toward **Asterisk** (this document) or toward **Kamailio P-CSCF** (IMS / VoLTE path in [`README_VOLTE_TWO_UE_CALLING.md`](./README_VOLTE_TWO_UE_CALLING.md)).

| Goal | What to use |
|------|-------------|
| LTE attach + ping | `apn = internet` |
| SIP desk phone / pjsua (MD5 password) | **Asterisk** on the LAN + SIP over `tun_srsue` |
| Operator-like IMS REGISTER (AKA) | Kamailio P-CSCF + pyHSS, **not** Asterisk |

---

## 1. What “disconnected” means here

Typical sequence after you change only the UE APN:

1. eNB still has S1.
2. UE attaches, NAS requests PDN **ims**.
3. MME/SMF/PCRF/eNB fail ERAB or ESM for that session.
4. srsUE tears down RRC. Console looks like detach / “disconnected” / no stable `tun_srsue`.

Confirm with logs (do not guess from the UE console alone):

```bash
# PC-1
docker logs srsue_zmq 2>&1 | tail -80
grep -E 'NAS|ESM|EMM|RRC|bearer|QCI|detach|release' srslte/ue.log | tail -50
grep -E 'ERAB|QCI|InitialContext|bearer' srslte/enb.log | tail -50

# PC-2
docker logs mme 2>&1 | grep -iE 'imsi|apn|pdn|esm|reject|ims' | tail -40
docker logs smf 2>&1 | grep -iE 'ims|dnn|pcrf|session|fail' | tail -40
docker logs pcrf 2>&1 | tail -40
docker logs upf 2>&1 | grep -iE 'ogstun2|ims' | tail -20
```

---

## 2. Root causes (most likely first)

### A. srsUE only brings up **one** PDN — the `[nas] apn` string

A commercial VoLTE phone requests **internet** (QCI 9) **and** **ims** (QCI 5). srsUE does not behave like that. If you set `apn = ims`, you **drop the internet default bearer** and ask the core to use IMS QoS as the **default** attach session.

Open5GS still needs the subscriber to include APN `ims` (WebUI or `open5gs-dbctl update_apn … ims`). If `ims` is missing, ESM/PDN reject → UE gives up.

### B. IMS uses **QCI 5**; internet uses **QCI 9**

In this project the IMS DNN is QCI **5** (IMS signalling). srsENB only sets up a radio bearer if `srslte/drb.conf` (or the image’s `qci_config`) contains that QCI.

If QCI 5 is missing:

* eNB **Initial Context Setup / E-RAB setup** fails (`radio network cause` / unspecified).
* UE never keeps a DRB → looks disconnected.

**Fix if you insist on IMS as the attach APN:** add QCI 5 (and QCI 1 if you later test GBR voice) to the eNB DRB profile. Example fragment used in srsRAN VoLTE labs:

```text
qci = 5;
pdcp_config = {
  discard_timer = -1;
  status_report_required = true;
};
rlc_config = {
  ul_am = { t_poll_retx = 80; poll_pdu = 128; poll_byte = 25000; max_retx_thresh = 4; };
  dl_am = { t_reordering = 80; t_status_prohibit = 60; };
};
logical_channel_config = { priority = 1; prioritized_bit_rate = -1; bucket_size_duration = 100; };
```

Copy the exact `qci_config` syntax from **your** `drb.conf` in the `docker_srslte` image (`docker exec srsenb_zmq cat /etc/srslte/drb.conf` or the bind-mounted `srslte/` tree). **This must be verified** against the file your image actually ships.

Keep QCI **9** for internet. Do not replace QCI 9 with QCI 5 on the internet APN.

### C. PCRF / Gx required for IMS, not for a plain internet ping

IMS session creation in 4G Open5GS goes through **PCRF**. If `pcrf` is down, Diameter Gx fails, or the subscriber has no IMS QoS profile, SMF rejects the session.

```bash
docker compose -f 4g-volte-deploy.yaml ps pcrf smf
docker logs pcrf 2>&1 | tail -50
```

Internet APN often still works when PCRF is unhappy; **ims** does not.

### D. PDN type: IPv4 vs IPv4v6

Keep the Open5GS **ims** slice as **IPv4** to match:

```ini
apn_protocol = ipv4
```

IPv4v6 / IPv6-only IMS slices are a common ESM mismatch with srsUE.

### E. UPF `ogstun2` (IMS pool `192.168.101.0/24`)

IMS addresses are on **`ogstun2`**, **no NAT** (so SIP can reach P-CSCF `172.22.0.21`). If `upf` did not create `ogstun2`, the IMS PDN has nowhere to land.

```bash
docker exec upf ip addr show ogstun2
```

Expect `192.168.101.1` (or the gateway from `.env` `UE_IPV4_IMS`).

### F. “IMS APN” in pyHSS is **not** what attaches the UE

pyHSS APN records matter for **IMS subscribers / Cx**. LTE attach APNs are **Open5GS HSS/WebUI**. Provisioning only pyHSS `apn: ims` will not make srsUE stay up.

---

## 3. Correct LTE settings (do this first)

**Open5GS subscriber (PC-2 WebUI):** both APNs present, **default = internet**.

```bash
docker exec -it webui misc/db/open5gs-dbctl add_ue_with_apn \
  001011234567895 \
  8baf473f2f8fd09487cccbd7097c6862 \
  8e27b6af0e692e750f32667a3b14605d \
  internet

docker exec -it webui misc/db/open5gs-dbctl update_apn 001011234567895 ims 0
```

**srsUE:** leave `apn = internet`. After attach:

```bash
docker exec srsue_zmq ip addr show tun_srsue
docker exec srsue_zmq ping -c 3 8.8.8.8
```

You should see **`192.168.100.x`**, not `192.168.101.x`.

A ready-made log collector is [`scripts/diagnose_ims_apn.sh`](./scripts/diagnose_ims_apn.sh).

---

## 4. If you still need an IMS PDN on srsUE

srsUE will **not** dual-APN like a phone. You can try **ims-only** attach after A–E above:

1. Subscriber includes `ims`, type IPv4, QCI 5, ARP 1.
2. eNB `drb.conf` has QCI 5.
3. `pcrf`, `smf`, `upf` up; `ogstun2` exists.
4. Then set `apn = ims` **once** as an experiment.

Even if `tun_srsue` gets `192.168.101.x`, you still have **no VoLTE** until a SIP client uses that tunnel. Prefer **internet + Asterisk** (below) or **internet/ims + Linphone AKA toward P-CSCF**.

---

## 5. Asterisk vs Kamailio in this project

```text
Asterisk  = PBX. Username/password Digest (MD5). Desk phones, pjsua, Linphone “SIP account”.
Kamailio  = this repo’s IMS (P/I/S-CSCF + pyHSS). Digest-AKAv1-MD5 with USIM K/OPc.
```

A Grandstream / Fanvil / Zoiper phone with password `1234` **will not** complete IMS REGISTER to P-CSCF. Point that phone at **Asterisk**.

Do **not** replace `4g-volte-deploy.yaml` with Asterisk. Run Asterisk **beside** Open5GS as a LAN PBX. SIP packets from the UE still ride the **internet** APN (NAT on `ogstun`).

```text
 PC-1                                      PC-2
 ┌─────────────────────────┐               ┌──────────────────────────────┐
 │ srsUE → tun_srsue       │  GTP-U        │ Open5GS UPF ogstun           │
 │   192.168.100.x         │──────────────►│   NAT 192.168.100.0/24       │
 │ pjsua / Linphone        │               │                              │
 │   REGISTER 1001         │               │ Asterisk :5060               │
 └─────────────────────────┘               │   1001 ← UE SIP client       │
                                           │   1002 ← desk SIP phone      │
           SIP phone 1002 ─────────────────┤   (LAN 10.195.138.20)        │
                                           └──────────────────────────────┘
```

This is **SIP over LTE data**, not VoLTE.

---

## 6. Integrate Asterisk (PC-2)

Install on **PC-2** (same LAN as EPC). Ubuntu example:

```bash
sudo apt update
sudo apt install -y asterisk
```

Example configs in this repo (copy, do not assume package paths are identical):

* [`asterisk/pjsip.conf.example`](./asterisk/pjsip.conf.example)
* [`asterisk/extensions.conf.example`](./asterisk/extensions.conf.example)

```bash
sudo cp asterisk/pjsip.conf.example /etc/asterisk/pjsip.conf
sudo cp asterisk/extensions.conf.example /etc/asterisk/extensions.conf
# Keep your distro modules.conf / asterisk.conf. Disable chan_sip if it fights PJSIP on :5060.
sudo systemctl restart asterisk
sudo asterisk -rx "pjsip show endpoints"
```

**Lab extensions**

| Number | Where it registers | Auth |
|--------|--------------------|------|
| `1001` | pjsua/Linphone **on PC-1**, bound to `tun_srsue` | `1001` / `1001pass` |
| `1002` | Hardware/soft SIP phone on the LAN | `1002` / `1002pass` |

Registrar / proxy for both: **`10.195.138.20`** UDP **5060**.

Kamailio P-CSCF in Docker also uses **5060 inside** `172.22.0.21`. Host-published IMS SIP is a separate design. If host `:5060` is already taken, either:

* bind Asterisk to `10.195.138.20:5060` only (not Docker bridge), or
* run Asterisk on **`5070`** and set that port on both phones.

```bash
sudo ss -ulnp | grep 5060
```

**This must be verified** on your PC-2 before phones REGISTER.

NAT from UPF: the UE source address Asterisk sees is typically **PC-2’s masquerade address**, not `192.168.100.x`. The example `pjsip.conf` therefore sets `rtp_symmetric`, `rewrite_contact`, and `force_rport`. Set `direct_media=no` so RTP stays through Asterisk.

Allow UDP RTP **10000–20000** on PC-2 if a firewall is on.

Desk phone: SIP server `10.195.138.20`, user `1002`, password `1002pass`, UDP.

---

## 7. SIP client on srsUE (PC-1)

1. Attach with **`apn = internet`**. Confirm `tun_srsue` and ping.
2. Run the SIP UA **in the same network namespace as the TUN** (UE container is `network_mode: host` + privileged, so the TUN is on the host/container as documented in your compose).

Install pjsua (one option):

```bash
sudo apt install -y pjsua
# or: sudo apt install -y linphone
```

Force signalling out the LTE tunnel (otherwise REGISTER goes out the LAN NIC and never proves the EPC path):

```bash
# UE_IP = address on tun_srsue, e.g. 192.168.100.2
UE_IP=$(ip -4 -o addr show tun_srsue | awk '{print $4}' | cut -d/ -f1)
echo "UE tunnel IP: $UE_IP"

pjsua --id sip:1001@10.195.138.20 \
  --registrar sip:10.195.138.20 \
  --realm '*' --username 1001 --password 1001pass \
  --local-port 5062 \
  --bound-addr "$UE_IP" \
  --ip-addr "$UE_IP"
```

If pjsua still uses the LAN IP, use policy routing (example; **verify** table id and interface name):

```bash
UE_IP=$(ip -4 -o addr show tun_srsue | awk '{print $4}' | cut -d/ -f1)
sudo ip rule add from "$UE_IP" table 100
sudo ip route add default dev tun_srsue table 100
```

A copy-paste helper: [`scripts/pjsua_over_tun.sh`](./scripts/pjsua_over_tun.sh).

In pjsua: `m` then dial `sip:1002@10.195.138.20`. The LAN phone should ring.

Linphone: account `1001` @ `10.195.138.20`, UDP, password `1001pass`. Bind/use `tun_srsue` if the UI allows an interface; otherwise use the `ip rule` above.

---

## 8. Call flow to verify

```text
pjsua 1001  --SIP REGISTER-->  Asterisk (10.195.138.20)
phone  1002 --SIP REGISTER-->  Asterisk
pjsua         INVITE 1002  -->  Asterisk  -->  1002
RTP via Asterisk (direct_media=no)
```

Captures:

```bash
# PC-2
sudo apt install -y sngrep
sudo sngrep -d any port 5060

# PC-1: SIP inside GTP looks like inner IP 192.168.100.x
sudo tcpdump -ni tun_srsue udp port 5060 -w ue-sip.pcap
```

| Check | Pass |
|-------|------|
| `pjsip show endpoints` | `1001` and `1002` `Avail` |
| sngrep | REGISTER 200, INVITE, 180/200 |
| Audio | RTP on Asterisk `rtp set debug on` |

---

## 9. Troubleshooting map

| Symptom | Layer | Action |
|---------|--------|--------|
| Change to `apn=ims` → UE drops | Default PDN / QCI 5 / PCRF | Put `apn=internet` back; see §2 |
| Attach OK, no `tun_srsue` | ESM | MME/SMF logs; subscriber APN list |
| Ping 8.8.8.8 fails | GTP-U / NAT | `SGWU_ADVERTISE_IP`, UDP 2152, `ogstun` |
| pjsua REGISTER timeout | Routing | Bind to `tun_srsue`; reach `10.195.138.20:5060` |
| REGISTER 401 forever | Auth | Username/password vs `pjsip.conf` |
| REGISTER 200, no ring | Dialplan | `extensions.conf` `Dial(PJSIP/1002)` |
| Ring, no audio | NAT/RTP | `direct_media=no`, RTP ports, symmetric RTP |
| Want AKA / IMS | Wrong PBX | Use Kamailio + Linphone AKA, not Asterisk |

---

## 10. What not to do

* Do not set srsUE `apn = ims` as the normal lab default.
* Do not point a password-only SIP phone at P-CSCF and call that VoLTE.
* Do not expect two srsUE processes to “call” without a SIP UA on each tunnel.
* Do not put Asterisk on `172.22.0.21` or replace Kamailio with Asterisk for IMS Cx.

When LTE data is stable (`192.168.100.x` + ping) and Asterisk shows two endpoints up, **1001 → 1002** is the srsUE-to-SIP-phone call this lab can actually place.

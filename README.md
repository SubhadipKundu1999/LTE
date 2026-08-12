# Two-PC LTE + IMS Lab Tutorial

**srsRAN UE + ZMQ eNodeB (PC-1) ↔ Open5GS EPC + Kamailio IMS (PC-2)**

This tutorial adapts [herlesupreeth/docker_open5gs](https://github.com/herlesupreeth/docker_open5gs) for a **two physical PC** lab. It is written so you can follow it from a fresh Ubuntu install, copy commands, and understand **what each step does and why**.

**New to EPC/IMS concepts?** Read the companion learning docs first:

* [`README_UE_JOURNEY_LTE_IMS.md`](./README_UE_JOURNEY_LTE_IMS.md) — absolute-beginner **story walkthrough** (one UE from cold start → IP → IMS REGISTER on your 2 PCs)
* [`README_BEGINNER_LTE_EPC_IMS.md`](./README_BEGINNER_LTE_EPC_IMS.md) — concept reference for APN, PDN/IP allocation, EPC↔IMS integration, databases, and protocols

Upstream repository (study this alongside this tutorial):

```text
https://github.com/herlesupreeth/docker_open5gs
```

> **Do not treat Docker container IPs as reachable from the other PC.**  
> The eNodeB on PC-1 reaches the MME/SGWU on PC-2 through **published host ports** on PC-2’s LAN IP, exactly as the upstream multihost section describes.

---

## Table of contents

1. [Final architecture](#1-final-architecture)
2. [Network topology](#2-network-topology)
3. [IP addressing plan](#3-ip-addressing-plan)
4. [Prerequisites](#4-prerequisites)
5. [PC-1 preparation](#5-pc-1-preparation)
6. [PC-2 preparation](#6-pc-2-preparation)
7. [Clone the docker_open5gs repository](#7-clone-the-docker_open5gs-repository)
8. [Required Docker images](#8-required-docker-images)
9. [Building the Docker images](#9-building-the-docker-images)
10. [Open5GS EPC configuration](#10-open5gs-epc-configuration)
11. [Subscriber configuration](#11-subscriber-configuration)
12. [APN configuration](#12-apn-configuration)
13. [IMS APN configuration](#13-ims-apn-configuration)
14. [Kamailio IMS configuration](#14-kamailio-ims-configuration)
15. [DNS configuration required for IMS](#15-dns-configuration-required-for-ims)
16. [PC-1 srsRAN installation](#16-pc-1-srsran-installation)
17. [ZMQ installation/configuration](#17-zmq-installationconfiguration)
18. [srsRAN eNodeB configuration](#18-srsran-enodeb-configuration)
19. [srsRAN UE configuration](#19-srsran-ue-configuration)
20. [Connecting eNodeB on PC-1 to MME on PC-2](#20-connecting-enodeb-on-pc-1-to-mme-on-pc-2)
21. [Connecting UE → eNodeB → EPC](#21-connecting-ue--enodeb--epc)
22. [Testing LTE attach](#22-testing-lte-attach) — see also [`ATTACH_SUCCESS_WALKTHROUGH.md`](./ATTACH_SUCCESS_WALKTHROUGH.md), [`troubleshoot.md`](./troubleshoot.md)
23. [Testing Internet/data connectivity](#23-testing-internetdata-connectivity)
24. [IMS registration](#24-ims-registration)
25. [Testing SIP/VoLTE](#25-testing-sipvolte)
26. [Packet capture and troubleshooting](#26-packet-capture-and-troubleshooting)
27. [Common errors and fixes](#27-common-errors-and-fixes)
28. [Complete startup sequence](#28-complete-startup-sequence)
29. [Complete shutdown sequence](#29-complete-shutdown-sequence)
30. [Final verification checklist](#30-final-verification-checklist)

---

## Your fixed lab IPs

| Role | Machine | LAN IP |
|------|---------|--------|
| RAN + UE | **PC-1** | `10.195.138.30` |
| EPC + IMS | **PC-2** | `10.195.138.20` |

If your LAN IPs differ later, replace every occurrence of these two addresses consistently.

---

## 1. Final architecture

```text
 PC-1 (10.195.138.30)                         PC-2 (10.195.138.20)
 ┌──────────────────────────────┐             ┌──────────────────────────────────────────┐
 │  srsUE  ◄──ZMQ I/Q──►  srsENB │             │  Docker Compose: 4g-volte-deploy.yaml     │
 │   (soft UE)           (eNB)   │             │                                          │
 │                         │     │             │  Open5GS EPC:                            │
 │                    S1AP (SCTP)│  Ethernet   │   MME ←S1AP── (published :36412/sctp)    │
 │                    GTP-U(UDP) ├────────────►│   SGWU←GTP-U──(published :2152/udp)      │
 │                         │     │             │   HSS, SGWC, SMF(PGW-C), UPF(PGW-U),     │
 │                         │     │             │   PCRF, WebUI, MongoDB                   │
 │                         │     │             │                                          │
 │                         │     │             │  Kamailio IMS + pyHSS:                   │
 │                         │     │             │   P-CSCF → I-CSCF → S-CSCF               │
 │                         │     │             │   DNS, MySQL, RTPEngine, OsmoHLR/MSC     │
 └──────────────────────────────┘             └──────────────────────────────────────────┘
```

### What runs where

| PC | Components | How they run |
|----|------------|--------------|
| **PC-2** | Open5GS EPC + Kamailio IMS + pyHSS + DNS + MySQL + RTPEngine + OsmoHLR/MSC | `docker compose -f 4g-volte-deploy.yaml` |
| **PC-1** | srsRAN eNodeB (ZMQ) + srsRAN UE (ZMQ) | `docker compose -f srsenb_zmq.yaml` and `srsue_zmq.yaml` with **`network_mode: host`** |

### Same-host assumptions in the upstream repo (important)

The default single-host setup assumes eNB + EPC + IMS share Docker network `docker_open5gs_default` (`172.22.0.0/24`). In that mode:

* eNB uses container IP `SRS_ENB_IP` (default `172.22.0.22`)
* MME uses container IP `MME_IP` (default `172.22.0.9`)
* SGWU advertises container IP `SGWU_ADVERTISE_IP` (default `172.22.0.6`)

**Those Docker IPs are NOT reachable from PC-1.**  
For two PCs you must follow the upstream **Multihost setup configuration → 4G deployment** pattern:

1. Publish MME SCTP `36412` and SGWU GTP-U `2152` on PC-2’s host.
2. Set `SGWU_ADVERTISE_IP` to PC-2’s LAN IP (`10.195.138.20`).
3. Point eNB `MME_IP` at PC-2’s LAN IP (`10.195.138.20`).
4. Run eNB (and UE) on PC-1 with `network_mode: host`.

---

## 2. Network topology

### Control plane (S1-MME / S1AP)

```text
srsENB (PC-1, 10.195.138.30)
    -- SCTP / S1AP --> 10.195.138.20:36412  (Docker publishes into mme container 172.22.0.9)
```

### User plane (S1-U / GTP-U)

```text
srsENB (PC-1, 10.195.138.30)
    -- UDP / GTP-U --> 10.195.138.20:2152   (Docker publishes into sgwu container;
                                             SGWU advertises 10.195.138.20 to the eNB)
    sgwu (172.22.0.6) <--> sgwc / smf / upf  (all inside Docker network on PC-2)
```

### RF simulation (ZMQ) — stays entirely on PC-1

```text
srsENB tx tcp://10.195.138.30:2000  <-->  srsUE  rx tcp://10.195.138.30:2000
srsUE  tx tcp://10.195.138.30:2001  <-->  srsENB rx tcp://10.195.138.30:2001
```

No SDR is required.

### IMS path (after UE has IMS PDN)

```text
UE  →  eNB  →  EPC (SGWU/UPF)  →  P-CSCF  →  I-CSCF  →  S-CSCF
                                      │                     │
                                      └──── Diameter Cx ────┘
                                              ↕
                                            pyHSS
```

Kamailio containers from `4g-volte-deploy.yaml`:

| Function | Compose service | Container | Default Docker IP |
|----------|-----------------|-----------|-------------------|
| P-CSCF | `pcscf` | `pcscf` | `172.22.0.21` |
| I-CSCF | `icscf` | `icscf` | `172.22.0.19` |
| S-CSCF | `scscf` | `scscf` | `172.22.0.20` |
| IMS HSS | `pyhss` | `pyhss` | `172.22.0.18` |
| IMS DNS | `dns` | `dns` | `172.22.0.15` |

---

## 3. IP addressing plan

### Physical LAN

| Name | Value | Notes |
|------|-------|-------|
| PC-1 LAN IP (RAN+UE) | `10.195.138.30` | eNB S1 bind + ZMQ endpoints |
| PC-2 LAN IP (EPC+IMS) | `10.195.138.20` | `DOCKER_HOST_IP`, MME publish target, SGWU advertise |

### Docker network on PC-2 (`TEST_NETWORK`)

| Name | Value | Role |
|------|-------|------|
| Docker subnet | `172.22.0.0/24` | Compose network `docker_open5gs_default` |
| `MONGO_IP` | `172.22.0.2` | MongoDB (Open5GS subscribers) |
| `HSS_IP` | `172.22.0.3` | Open5GS HSS |
| `PCRF_IP` | `172.22.0.4` | PCRF |
| `SGWC_IP` | `172.22.0.5` | SGW-C |
| `SGWU_IP` | `172.22.0.6` | SGW-U (GTP-U inside Docker) |
| `SGWU_ADVERTISE_IP` | **`10.195.138.20`** | **What eNB uses for GTP-U (must be PC-2 LAN IP)** |
| `SMF_IP` | `172.22.0.7` | SMF / PGW-C |
| `UPF_IP` | `172.22.0.8` | UPF / PGW-U |
| `MME_IP` (inside Docker on PC-2) | `172.22.0.9` | MME container address |
| `DNS_IP` | `172.22.0.15` | IMS/EPC DNS |
| `RTPENGINE_IP` | `172.22.0.16` | RTPEngine |
| `MYSQL_IP` | `172.22.0.17` | MySQL (IMS) |
| `PYHSS_IP` | `172.22.0.18` | pyHSS |
| `ICSCF_IP` | `172.22.0.19` | I-CSCF |
| `SCSCF_IP` | `172.22.0.20` | S-CSCF |
| `PCSCF_IP` | `172.22.0.21` | P-CSCF (also pushed to UE via PCO) |
| `WEBUI_IP` | `172.22.0.26` | Open5GS WebUI |
| `OSMOMSC_IP` | `172.22.0.31` | OsmoMSC (SMS over SGs) |
| `OSMOHLR_IP` | `172.22.0.32` | OsmoHLR |

### Addresses used by PC-1 (host network)

| Name | Value on PC-1 `.env` | Meaning |
|------|----------------------|---------|
| `DOCKER_HOST_IP` | `10.195.138.30` | Host running eNB/UE |
| `MME_IP` | **`10.195.138.20`** | **PC-2 LAN IP (published MME), NOT 172.22.0.9** |
| `SRS_ENB_IP` | `10.195.138.30` | eNB S1/GTP bind + ZMQ TX |
| `SRS_UE_IP` | `10.195.138.30` | UE ZMQ TX (same host IP; different TCP ports) |

### UE tunnel / APN pools (assigned by EPC on PC-2)

| Name | Value | Meaning |
|------|-------|---------|
| `UE_IPV4_INTERNET` | `192.168.100.0/24` | Internet APN UE addresses |
| `UE_IPV4_IMS` | `192.168.101.0/24` | IMS APN UE addresses |
| Example UE internet IP | `192.168.100.x` | Appears on `tun_srsue` after attach |
| Example UE IMS IP | `192.168.101.x` | Appears when IMS PDN is established |

### ZMQ endpoints (PC-1 only)

| Direction | Endpoint |
|-----------|----------|
| eNB → UE (DL I/Q) | `tcp://10.195.138.30:2000` |
| UE → eNB (UL I/Q) | `tcp://10.195.138.30:2001` |

### How eNB reaches MME across two machines

```text
WRONG:  eNB → 172.22.0.9:36412     (Docker-internal; unreachable from PC-1)
RIGHT:  eNB → 10.195.138.20:36412  (PC-2 host; Docker DNAT into mme container)
```

Same idea for GTP-U:

```text
WRONG:  eNB → 172.22.0.6:2152
RIGHT:  eNB → 10.195.138.20:2152   (because SGWU_ADVERTISE_IP=10.195.138.20)
```

---

## 4. Prerequisites

### Both PCs

* Ubuntu **22.04 or newer** (upstream tested setup)
* Ethernet connectivity between `10.195.138.30` and `10.195.138.20` (same L2/L3 LAN)
* Ability to disable or open host firewalls (UFW often blocks SCTP/GTP)
* Root/sudo access

### Software versions (from upstream README)

* Docker CE **22.0.5+**
* Docker Compose **v2.14+**

### PC-2 specific

* Enough RAM/CPU for many containers (EPC + IMS is heavy)
* IP forwarding enabled
* Ports free on host: `36412/sctp`, `2152/udp`, `9999/tcp`, `8080/tcp`, `3000/tcp`

### PC-1 specific

* No SDR required for this lab
* `libzmq` is already included inside the `docker_srslte` image
* Host networking for eNB/UE containers

### Useful tools (install on both)

**Run on:** PC-1 and PC-2  
**Directory:** any

```bash
sudo apt update
sudo apt install -y git curl wget iproute2 iputils-ping net-tools \
  tcpdump tshark sngrep libsctp-dev lksctp-tools traceroute
```

**Purpose:** cloning, connectivity checks, SCTP/GTP/SIP troubleshooting.

---

## 5. PC-1 preparation

**Run on:** PC-1  
**Directory:** any

### 5.1 Confirm LAN IP

```bash
ip -4 addr show
ip route
```

**Purpose:** verify this machine is `10.195.138.30` and has a route to `10.195.138.20`.

**Expected result:** an interface owns `10.195.138.30/xx`.

**If it fails, check:** cabling, DHCP/static config, VLAN, `ip addr add 10.195.138.30/24 dev <iface>`.

### 5.2 Ping PC-2

```bash
ping -c 3 10.195.138.20
```

**Purpose:** confirm L3 reachability before any S1 work.

### 5.3 Install Docker on PC-1

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER
```

**Purpose:** run `docker_srslte` eNB/UE containers.

Log out/in (or reboot) so the `docker` group applies.

### 5.4 Host tuning on PC-1

```bash
sudo ufw disable
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0
```

**Purpose:** avoid firewall drops on GTP-U return traffic; allow forwarding if needed for UE TUN testing from the host.

> Persist sysctl settings under `/etc/sysctl.d/` if you want them across reboots. Exact persistence method is distro-specific — **This must be verified before continuing** if reboots reset your lab.

### 5.5 Optional: performance governor

```bash
sudo apt install -y linux-tools-common linux-tools-generic
sudo cpupower frequency-set -g performance
```

**Purpose:** recommended by upstream for realtime-ish RAN simulation.

---

## 6. PC-2 preparation

**Run on:** PC-2  
**Directory:** any

### 6.1 Confirm LAN IP

```bash
ip -4 addr show
ping -c 3 10.195.138.30
```

**Purpose:** verify `10.195.138.20` and reachability to PC-1.

### 6.2 Install Docker on PC-2

Use the same Docker install commands as section 5.3 on PC-2.

### 6.3 Host tuning on PC-2 (mandatory for EPC)

```bash
sudo ufw disable
sudo sysctl -w net.ipv4.ip_forward=1
sudo cpupower frequency-set -g performance
```

**Purpose:**

* `ip_forward=1` — UPF/NAT and Docker published ports need forwarding
* disable UFW — SCTP `36412` and UDP `2152` are otherwise easy to block
* performance governor — upstream recommendation

### 6.4 Load SCTP (if needed)

```bash
sudo modprobe sctp
lsmod | grep sctp
```

**Purpose:** MME↔eNB uses SCTP. Some minimal kernels need the module loaded.

**Expected result:** `sctp` appears in `lsmod`.

**If it fails, check:** `sudo apt install -y linux-modules-extra-$(uname -r)` then retry `modprobe sctp`. Exact package name **must be verified** for your Ubuntu kernel.

---

## 7. Clone the docker_open5gs repository

Clone on **both** PCs (PC-2 needs full EPC/IMS; PC-1 needs eNB/UE compose + configs).

**Run on:** PC-1 and PC-2  
**Directory:** `$HOME` (or your preferred workspace)

```bash
git clone https://github.com/herlesupreeth/docker_open5gs.git
cd docker_open5gs
```

**Purpose:** obtain compose files, `.env`, Open5GS/Kamailio/srsRAN configs used by this tutorial.

All later paths are relative to this `docker_open5gs` directory unless stated otherwise.

---

## 8. Required Docker images

For this two-PC **4G + Kamailio IMS + ZMQ RAN** lab you need:

| Image | Used for | Where |
|-------|----------|-------|
| `docker_open5gs` | Open5GS EPC/WebUI components | PC-2 |
| `docker_kamailio` | P/I/S-CSCF, SMSC | PC-2 |
| `docker_pyhss` | IMS HSS | PC-2 |
| `docker_mysql` | IMS databases | PC-2 |
| `docker_dns` | IMS/EPC DNS (built by compose) | PC-2 |
| `docker_rtpengine` | media (built by compose) | PC-2 |
| `docker_osmohlr` / `docker_osmomsc` | SMS over SGs helpers | PC-2 |
| `docker_metrics` / `docker_grafana` | optional metrics | PC-2 |
| `mongo:6.0` | Open5GS DB | PC-2 |
| `docker_srslte` | srsENB + srsUE | **PC-1** (build/pull here) |

You do **not** need for this tutorial: UERANSIM, srsRAN_Project 5G gNB, OpenSIPS IMS, OCS, ePDG/VoWiFi images.

---

## 9. Building the Docker images

You can **pull prebuilt images** (faster) or **build from source**.

### Option A — Pull prebuilt (recommended to start)

#### On PC-2

**Run on:** PC-2  
**Directory:** `~/docker_open5gs`

```bash
docker pull ghcr.io/herlesupreeth/docker_open5gs:master
docker tag ghcr.io/herlesupreeth/docker_open5gs:master docker_open5gs

docker pull ghcr.io/herlesupreeth/docker_kamailio:master
docker tag ghcr.io/herlesupreeth/docker_kamailio:master docker_kamailio

docker pull ghcr.io/herlesupreeth/docker_pyhss:master
docker tag ghcr.io/herlesupreeth/docker_pyhss:master docker_pyhss

docker pull ghcr.io/herlesupreeth/docker_mysql:master
docker tag ghcr.io/herlesupreeth/docker_mysql:master docker_mysql

docker pull ghcr.io/herlesupreeth/docker_osmohlr:master
docker tag ghcr.io/herlesupreeth/docker_osmohlr:master docker_osmohlr

docker pull ghcr.io/herlesupreeth/docker_osmomsc:master
docker tag ghcr.io/herlesupreeth/docker_osmomsc:master docker_osmomsc

docker pull ghcr.io/herlesupreeth/docker_metrics:master
docker tag ghcr.io/herlesupreeth/docker_metrics:master docker_metrics

docker pull ghcr.io/herlesupreeth/docker_grafana:master
docker tag ghcr.io/herlesupreeth/docker_grafana:master docker_grafana
```

**Purpose:** provide images referenced by `4g-volte-deploy.yaml`.

Then build the compose-local images (DNS, RTPEngine, metrics helpers, etc.):

```bash
set -a
source .env
set +a
docker compose -f 4g-volte-deploy.yaml build
```

**Purpose:** build services that use `build:` in the compose file (`dns`, `rtpengine`, `mysql`, `pyhss`, `osmomsc`, `osmohlr`, `metrics`).

#### On PC-1

**Run on:** PC-1  
**Directory:** `~/docker_open5gs`

```bash
docker pull ghcr.io/herlesupreeth/docker_srslte:master
docker tag ghcr.io/herlesupreeth/docker_srslte:master docker_srslte
```

**Purpose:** srsRAN_4G eNB + UE image with ZMQ support.

### Option B — Build from source

#### Base images on PC-2

**Run on:** PC-2  
**Directory:** `~/docker_open5gs/base`

```bash
docker build --no-cache --force-rm -t docker_open5gs .
```

**Run on:** PC-2  
**Directory:** `~/docker_open5gs/ims_base`

```bash
docker build --no-cache --force-rm -t docker_kamailio .
```

Then:

**Run on:** PC-2  
**Directory:** `~/docker_open5gs`

```bash
set -a
source .env
set +a
docker compose -f 4g-volte-deploy.yaml build
```
If you change the .env file later, the variables already loaded into yourcurrent shell do not automatically update. so to Load everything in .env and export it, then return the shell to normal for that every time there is change in **.env** file do 
```bash
set -a
source .env
set +a
```

	

#### srsRAN image on PC-1

**Run on:** PC-1  
**Directory:** `~/docker_open5gs/srslte`

```bash
docker build --no-cache --force-rm -t docker_srslte .
```

**Purpose:** compile srsRAN_4G + ZMQ + dependencies inside Docker (slow but reproducible).

---

## 10. Open5GS EPC configuration

All edits in this section are on **PC-2**.

### 10.1 Edit `.env` on PC-2

**File path:** `docker_open5gs/.env`

| Parameter | Original (repo default) | Required for this topology | Reason |
|-----------|-------------------------|----------------------------|--------|
| `MCC` | `001` | `001` | PLMN; must match eNB/UE |
| `MNC` | `01` | `01` | PLMN; must match eNB/UE |
| `DOCKER_HOST_IP` | `192.168.1.223` | **`10.195.138.20`** | PC-2 LAN IP |
| `SGWU_ADVERTISE_IP` | `172.22.0.6` | **`10.195.138.20`** | eNB must send GTP-U to PC-2 host, not Docker IP |
| `UE_IPV4_INTERNET` | `192.168.100.0/24` | keep / change if conflicted | UE internet pool |
| `UE_IPV4_IMS` | `192.168.101.0/24` | keep / change if conflicted | UE IMS pool |
| `MME_IP` | `172.22.0.9` | **keep `172.22.0.9`** | MME address **inside** Docker on PC-2 |
| `SGWU_IP` | `172.22.0.6` | **keep `172.22.0.6`** | SGWU listen address inside Docker |

Example block after editing:

```bash
MCC=001
MNC=01
TAC=1

TEST_NETWORK=172.22.0.0/24
DOCKER_HOST_IP=10.195.138.20

SGWU_IP=172.22.0.6
SGWC_IP=172.22.0.5
SGWU_ADVERTISE_IP=10.195.138.20

MME_IP=172.22.0.9

UE_IPV4_INTERNET=192.168.100.0/24
UE_IPV4_IMS=192.168.101.0/24

UE1_IMSI=001011234567895
UE1_KI=8baf473f2f8fd09487cccbd7097c6862
UE1_OP=11111111111111111111111111111111
UE1_AMF=8000
```

**Why `SGWU_ADVERTISE_IP` matters**

`sgwu/sgwu.yaml` contains:

```yaml
sgwu:
    gtpu:
      server:
        - address: SGWU_IP
          advertise: SGWU_ADVERTISE_IP
```

Open5GS tells the eNB (via S1) to send GTP-U to the **advertise** address. In multihost mode that must be the **host LAN IP**.

### 10.2 Publish MME and SGWU ports in compose

**File path:** `docker_open5gs/4g-volte-deploy.yaml`

#### MME — uncomment S1AP publish

**Original:**

```yaml
    # ports:
    #   - "36412:36412/sctp"
```

**Required:**

```yaml
    ports:
      - "36412:36412/sctp"
```

**Reason:** PC-1 eNB cannot reach `172.22.0.9`. Publishing maps `10.195.138.20:36412` → MME container.

#### SGWU — uncomment GTP-U publish

**Original:**

```yaml
    # ports:
    #   - "2152:2152/udp"
```

**Required:**

```yaml
    ports:
      - "2152:2152/udp"
```

**Reason:** PC-1 eNB must send GTP-U to PC-2 host UDP/2152.

### 10.3 MME PLMN / S1AP bind (usually no manual IP edit)

**File path:** `mme/mme.yaml` (templated; values substituted by `mme/mme_init.sh`)

Relevant template:

```yaml
mme:
    s1ap:
      server:
        - dev: MME_IF
    gummei:
      - plmn_id:
          mcc: MCC
          mnc: MNC
        mme_gid: 2
        mme_code: 1
    tai:
      - plmn_id:
          mcc: MCC
          mnc: MNC
        tac: TAC
```

`mme_init.sh` replaces `MCC`/`MNC`/`TAC` from `.env` and binds S1AP on the container interface. You normally **do not** hardcode PC-2’s LAN IP inside `mme.yaml` when using Docker port publish.

### 10.4 Start EPC+IMS on PC-2

**Run on:** PC-2  
**Directory:** `~/docker_open5gs`

```bash
set -a
source .env
set +a
docker compose -f 4g-volte-deploy.yaml up
```

**Purpose:** start MongoDB, Open5GS (MME/HSS/SGW/SMF/UPF/PCRF/WebUI), Kamailio IMS, pyHSS, DNS, MySQL, RTPEngine, OsmoHLR/MSC, metrics.

First boot can take several minutes (MySQL init, cert generation, Kamailio DB bootstrap).

**Expected result:** containers stay up; WebUI reachable at `http://10.195.138.20:9999`.

**If it fails, check:** `docker compose -f 4g-volte-deploy.yaml ps`, `docker logs mme`, `docker logs sgwu`, free ports, `.env` syntax.

---

## 11. Subscriber configuration

You need **one subscriber** that matches across:

1. srsUE (`srslte/ue_zmq.conf` via `.env` placeholders)
2. Open5GS HSS (authentication + APNs)
3. OsmoHLR (MSISDN mapping used by the repo’s SMS path)
4. pyHSS (IMS authentication / Cx)

### 11.1 Example subscriber (use these exact matching values)

| Field | Value | Where it must match |
|-------|-------|---------------------|
| IMSI | `001011234567895` | srsUE + Open5GS + OsmoHLR + pyHSS |
| MCC / MNC | `001` / `01` | `.env`, eNB, MME TAI/GUMMEI |
| K / Ki | `8baf473f2f8fd09487cccbd7097c6862` | srsUE + Open5GS + pyHSS |
| OP | `11111111111111111111111111111111` | srsUE (`.env` `UE1_OP`) |
| OPc | `8e27b6af0e692e750f32667a3b14605d` | Open5GS/pyHSS when using OPc form of the same OP+K |
| AMF | `8000` | Open5GS + pyHSS |
| MSISDN | `9076543210` | Open5GS + OsmoHLR + pyHSS IMS |
| Internet APN | `internet` | srsUE `[nas] apn` + Open5GS subscriber |
| IMS APN | `ims` | Open5GS + SMF/UPF session DNN |
| IMS private ID | `001011234567895@ims.mnc001.mcc001.3gppnetwork.org` | pyHSS / SIP REGISTER |
| IMS public ID | `sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org` | pyHSS / SIP |

> With default `.env` values, **OP `1111…` + K above derive OPc `8e27b6af…`**.  
> Upstream README examples that show this OPc are consistent with the default K/OP pair.

check parameters in each .env file:
Run:
```
echo "========== PC-1 : srsUE / srsENB =========="
echo "MCC       = $MCC"
echo "MNC       = $MNC"
echo "HOST IP   = $DOCKER_HOST_IP"
echo "MME IP    = $MME_IP"
echo "eNB IP    = $SRS_ENB_IP"
echo "UE IP     = $SRS_UE_IP"
echo "--------------------------------------------"
echo "IMSI      = $UE1_IMSI"
echo "KI        = $UE1_KI"
echo "OP        = $UE1_OP"
echo "AMF       = $UE1_AMF"
echo "IMEI      = $UE1_IMEI"
echo "IMEISV    = $UE1_IMEISV"
echo "============================================"
```

##PC-2 — Open5GS side
For .env variables, run:
```
cd ~/docker_open5gs

set -a
source .env
set +a

echo "========== PC-2 : Open5GS EPC + IMS =========="
echo "MCC                = $MCC"
echo "MNC                = $MNC"
echo "HOST IP            = $DOCKER_HOST_IP"
echo "MME Docker IP      = $MME_IP"
echo "SGWU Docker IP     = $SGWU_IP"
echo "SGWU Advertise IP  = $SGWU_ADVERTISE_IP"
echo "UE Internet Pool   = $UE_IPV4_INTERNET"
echo "UE IMS Pool        = $UE_IPV4_IMS"
echo "================================================"
```
The key comparison we ultimately want is:
```
PC-1 srsUE                    PC-2 Open5GS subscriber
------------------            ------------------------
IMSI 001011234567895   ==     IMSI 001011234567895
K    8baf...6862       ==     K    8baf...6862
OP   1111...1111       ==     OP   1111...1111
AMF  8000              ==     AMF  8000

MCC  001               ==     MCC 001
MNC  01                ==     MNC 01
```
### 11.2 Provision Open5GS HSS (WebUI)




---

#### Open Open5GS WebUI

Browse to:

```text
http://10.195.138.20:9999
```

Navigate to:

```
Subscribers → Add Subscriber
```

---

#### Subscriber Configuration

| Field | Value |
|-------|-------|
| IMSI | `001011234567895` |
| Subscriber Key (K) | `8baf473f2f8fd09487cccbd7097c6862` |
| Authentication Management Field (AMF) | `8000` |
| USIM Type | `OP` |
| Operator Key (OP) | `11111111111111111111111111111111` |
| UE-AMBR Downlink | `1 Gbps` |
| UE-AMBR Uplink | `1 Gbps` |
| Subscriber Status | Default |
| Operator Determined Barring | Default |

> **Important**
>
> Since the UE configuration uses **OP**, select **OP** in the WebUI. Do **not** select **OPc**.

---

#### Slice Configuration

Use the default slice.

| Field | Value |
|-------|-------|
| SST | `1` |
| SD | Leave Blank |
| Default S-NSSAI | ✔ Enabled |

---

#### Session Configuration 1 (Internet)

Click **Add Session**.

| Field | Value |
|-------|-------|
| DNN / APN | `internet` |
| Type | `IPv4` |
| LBO Roaming Allowed | Disabled |
| 5QI / QCI | `9` |
| ARP Priority Level | `8` |
| Capability | Enabled |
| Vulnerability | Disabled |
| Session-AMBR Downlink | `1 Gbps` |
| Session-AMBR Uplink | `1 Gbps` |
| UE IPv4 Address | Leave Blank |
| UE IPv6 Address | Leave Blank |
| SMF IPv4 Address | Leave Blank |
| SMF IPv6 Address | Leave Blank |
| PCC Rules | Leave Blank |

This APN provides normal LTE Internet connectivity.

---

#### Session Configuration 2 (IMS)

Click **Add Session** again.

| Field | Value |
|-------|-------|
| DNN / APN | `ims` |
| Type | `IPv4` |
| LBO Roaming Allowed | Disabled |
| 5QI / QCI | `5` |
| ARP Priority Level | `1` |
| Capability | Enabled |
| Vulnerability | Disabled |
| Session-AMBR Downlink | `1 Gbps` |
| Session-AMBR Uplink | `1 Gbps` |
| UE IPv4 Address | Leave Blank |
| UE IPv6 Address | Leave Blank |
| SMF IPv4 Address | Leave Blank |
| SMF IPv6 Address | Leave Blank |
| PCC Rules | Leave Blank |

This APN is used for IMS/VoLTE registration.

---

#### Final Subscriber Configuration

```
Subscriber
│
├── IMSI : 001011234567895
├── K    : 8baf473f2f8fd09487cccbd7097c6862
├── OP   : 11111111111111111111111111111111
├── AMF  : 8000
│
├── Session 1
│     APN  : internet
│     Type : IPv4
│     QCI  : 9
│     ARP  : 8
│
└── Session 2
      APN  : ims
      Type : IPv4
      QCI  : 5
      ARP  : 1
```

---

#### Verification

The subscriber credentials must exactly match the UE configuration on **PC-1**.

| UE Configuration | Open5GS Subscriber |
|------------------|--------------------|
| IMSI | IMSI |
| K | Subscriber Key (K) |
| OP | Operator Key (OP) |
| AMF | Authentication Management Field |

---

#### APN Mapping

| APN | Purpose | UE Address Pool |
|------|---------|-----------------|
| `internet` | LTE Data | `192.168.100.0/24` |
| `ims` | IMS / VoLTE | `192.168.101.0/24` |

---

#### Expected Topology

```text
PC-1 (10.195.138.30)

srsUE
   │
   │ APN = internet
   ▼
srsENB
   │
   │ S1-MME
   ▼

PC-2 (10.195.138.20)

Open5GS EPC
│
├── APN: internet → 192.168.100.0/24
└── APN: ims      → 192.168.101.0/24

           │
           ▼

     Kamailio IMS
```


### 11.3 Provision via CLI (alternative)

**Run on:** PC-2  
**Directory:** any

```bash
docker exec -it webui misc/db/open5gs-dbctl add_ue_with_apn \
  001011234567895 \
  8baf473f2f8fd09487cccbd7097c6862 \
  8e27b6af0e692e750f32667a3b14605d \
  internet

docker exec -it webui misc/db/open5gs-dbctl update_apn 001011234567895 ims 0
```

**Purpose:** create UE with internet APN, then add IMS APN. The third key argument is **OPc** in this helper.

### 11.4 Provision OsmoHLR MSISDN

**Run on:** PC-2

```bash
telnet 172.22.0.32 4258
```

Inside OsmoHLR:

```text
enable
subscriber imsi 001011234567895 create
subscriber imsi 001011234567895 update msisdn 9076543210
```

**Purpose:** map IMSI↔MSISDN for the SMS-over-SGs components included in `4g-volte-deploy.yaml`.

### 11.5 Provision pyHSS (required for IMS)

Open Swagger UI: `http://10.195.138.20:8080/docs/`

Follow the upstream order: **APN → AUC → SUBSCRIBER → IMS_SUBSCRIBER**.

1. Create APNs `internet` and `ims` (once).

Select apn -> Create new APN -> Press on Try it out. Then, in payload section use the below JSON and then press Execute
```{
  "apn": "internet",
  "apn_ambr_dl": 0,
  "apn_ambr_ul": 0
}
```
Take note of apn_id specified in Response body under Server response for internet APN

Repeat creation step for following payload
```
{
  "apn": "ims",
  "apn_ambr_dl": 0,
  "apn_ambr_ul": 0
}
```
2. Create AUC: select auc -> Create new AUC -> Press on Try it out. Then, in payload section use the below example JSON to fill in ki, opc and amf for your SIM and then press Execute

```
json
{
  "ki": "8baf473f2f8fd09487cccbd7097c6862",
  "opc": "8e27b6af0e692e750f32667a3b14605d",
  "amf": "8000",
  "sqn": 0,
  "imsi": "001011234567895"
}
```
Take note of auc_id specified in Response body under Server response

3. Create subscriber (replace `auc_id` / APN IDs with values returned by the API):Next, select subscriber -> Create new SUBSCRIBER -> Press on Try it out. Then, in payload section use the below example JSON to fill in imsi, auc_id and apn_list for your SIM and then press Execute

```json
{
  "imsi": "001011234567895",
  "enabled": true,
  "auc_id": 1,
  "default_apn": 1,
  "apn_list": "1,2",
  "msisdn": "9076543210",
  "ue_ambr_dl": 0,
  "ue_ambr_ul": 0
}
```
* auc_id is the ID of the AUC created in the previous steps
* default_apn is the ID of the internet APN created in the previous steps
* apn_list is the comma separated list of APN IDs allowed for the UE i.e. APN ID for internet and ims APN created in the previous steps

4. Create IMS subscriber:
   Finally, select ims_subscriber -> Create new IMS SUBSCRIBER -> Press on Try it out. Then, in payload section use the below example JSON to fill in imsi, msisdn, msisdn_list, scscf_peer, scscf_realm and scscf for your SIM/deployment and then press Execute

```json
{
  "imsi": "001011234567895",
  "msisdn": "9076543210",
  "sh_profile": "string",
  "scscf_peer": "scscf.ims.mnc001.mcc001.3gppnetwork.org",
  "msisdn_list": "[9076543210]",
  "ifc_path": "default_ifc.xml",
  "scscf": "sip:scscf.ims.mnc001.mcc001.3gppnetwork.org:6060",
  "scscf_realm": "ims.mnc001.mcc001.3gppnetwork.org"
}
```
Replace imsi, msisdn and msisdn_list as per your programmed SIM

Replace scscf_peer, scscf and scscf_realm as per your deployment

**Purpose:** S-CSCF uses Diameter Cx against pyHSS during IMS registration.

> `auc_id` / `apn_list` IDs **must be verified** from the API responses on your deployment before continuing.

---

## 12. APN configuration

Internet APN is already defined in SMF/UPF templates.

**File path:** `smf/smf_4g.yaml` (used when `DEPLOY_MODE=4G`)

```yaml
smf:
    session:
      - subnet: UE_IPV4_INTERNET_APN_SUBNET
        gateway: UE_IPV4_INTERNET_APN_GATEWAY_IP
        dnn: internet
      - subnet: UE_IPV4_IMS_SUBNET
        gateway: UE_IPV4_IMS_TUN_IP
        dnn: ims
    dns:
      - SMF_DNS1
      - SMF_DNS2
    p-cscf:
      - PCSCF_IP
```

Substituted from `.env` by `smf/smf_init.sh`:

* `dnn: internet` → pool `UE_IPV4_INTERNET` (`192.168.100.0/24`)
* DNS defaults: `SMF_DNS1=8.8.8.8`, `SMF_DNS2=8.8.4.4`
* P-CSCF address pushed via PCO: `PCSCF_IP` (`172.22.0.21`)

**srsUE side** (`srslte/ue_zmq.conf`):

```ini
[nas]
apn = internet
apn_protocol = ipv4
```

No change needed for basic data attach.

---

## 13. IMS APN configuration

IMS DNN is already present in SMF/UPF (`dnn: ims`, pool `192.168.101.0/24`).

**File path:** `upf/upf.yaml`

```yaml
upf:
    session:
      - subnet: UE_IPV4_INTERNET_APN_SUBNET
        dnn: internet
        dev: UPF_INTERNET_APN_IF_NAME
      - subnet: UE_IPV4_IMS_SUBNET
        dnn: ims
        dev: UPF_IMS_APN_IF_NAME
```

`upf/upf_init.sh` creates `ogstun` (internet, with NAT) and `ogstun2` (IMS, **no NAT**), and excludes `PCSCF_IP` from NAT so SIP can reach P-CSCF.

**Subscriber requirement:** Open5GS subscriber must include APN `ims` (section 11).

**Important limitation (srsUE):**  
stock `ue_zmq.conf` requests **`internet` only**. Full IMS PDN + SIP stack is **not** a complete out-of-the-box VoLTE UE in srsRAN_4G the way a commercial phone is. Section 24 explains what works and what you must verify.

---

## 14. Kamailio IMS configuration

For this lab, use the repository’s Kamailio configs as-is. They are templated by init scripts from `.env`.

| Role | Config directory | Compose service |
|------|------------------|-----------------|
| P-CSCF | `pcscf/` | `pcscf` |
| I-CSCF | `icscf/` | `icscf` |
| S-CSCF | `scscf/` | `scscf` |

Init scripts replace `PCSCF_IP`, `ICSCF_IP`, `SCSCF_IP`, `IMS_DOMAIN`, Diameter ports, etc.

### IMS signalling path

1. UE sends SIP REGISTER toward **P-CSCF** (`pcscf`, port `5060`)
2. P-CSCF forwards to **I-CSCF** (`icscf`, port `4060`)
3. I-CSCF queries **pyHSS** (Diameter Cx) and selects **S-CSCF**
4. **S-CSCF** (`scscf`, port `6060`) authenticates via pyHSS and completes registration

### Diameter

* S-CSCF / I-CSCF ↔ pyHSS use Diameter Cx over the Docker network
* P-CSCF may use Rx toward PCRF in 4G mode (`DEPLOY_MODE=4G` keeps Rx enabled in `pcscf_init.sh`)

You should **not** invent a separate Kamailio config for this tutorial; use `4g-volte-deploy.yaml` + repo `pcscf`/`icscf`/`scscf` trees.

---

## 15. DNS configuration required for IMS

**Compose service:** `dns`  
**Files:** `dns/ims_zone`, `dns/epc_zone`, `dns/named.conf`  
**Init:** `dns/dns_init.sh`

With `MCC=001`, `MNC=01` the IMS domain becomes:

```text
ims.mnc001.mcc001.3gppnetwork.org
```

`dns/ims_zone` (after substitution) publishes A/SRV records for:

* `pcscf.ims.mnc001.mcc001.3gppnetwork.org` → `PCSCF_IP`
* `icscf...` → `ICSCF_IP`
* `scscf...` → `SCSCF_IP`
* `hss...` → `PYHSS_IP`

Kamailio containers are started with `dns: ${DNS_IP}` so they resolve these names internally.

**Note:** `4g-volte-deploy.yaml` does **not** publish DNS port `53` to the host by default (the VoWiFi compose file does). Internal IMS containers still work. If you need host/UE DNS lookups against this server from outside Docker, publish `53/udp`+`53/tcp` or point clients at `172.22.0.15` from a container on the same network — **This must be verified before continuing** for your IMS client design.

Optional for better UE-side IMS name resolution later: set in PC-2 `.env`:

```bash
SMF_DNS1=172.22.0.15
SMF_DNS2=8.8.8.8
```

**Reason:** SMF can push the IMS DNS to the UE via protocol config options. Whether your UE/IMS client actually uses it **must be verified**.

---

## 16. PC-1 srsRAN installation

Preferred method (matches upstream): use **`docker_srslte`** (already pulled/built in section 9).

### 16.1 Edit `.env` on PC-1

**File path:** `docker_open5gs/.env` **on PC-1** (separate clone from PC-2)

| Parameter | Required value | Reason |
|-----------|----------------|--------|
| `MCC` | `001` | must match PC-2 |
| `MNC` | `01` | must match PC-2 |
| `DOCKER_HOST_IP` | `10.195.138.30` | this host |
| `MME_IP` | **`10.195.138.20`** | PC-2 LAN (published MME) |
| `SRS_ENB_IP` | `10.195.138.30` | eNB bind + ZMQ |
| `SRS_UE_IP` | `10.195.138.30` | UE ZMQ on same host |
| `UE1_IMSI` / `UE1_KI` / `UE1_OP` | match section 11 | must match Open5GS |

Example:

```bash
MCC=001
MNC=01
TAC=1

DOCKER_HOST_IP=10.195.138.30
MME_IP=10.195.138.20
SRS_ENB_IP=10.195.138.30
SRS_UE_IP=10.195.138.30

UE1_IMSI=001011234567895
UE1_KI=8baf473f2f8fd09487cccbd7097c6862
UE1_OP=11111111111111111111111111111111
UE1_AMF=8000
```

### 16.2 Native srsRAN_4G install (optional alternative)

If you prefer bare-metal instead of Docker on PC-1:

* Build [srsRAN_4G](https://github.com/srsran/srsRAN_4G) with ZeroMQ enabled
* Install `libzmq3-dev`
* Copy/adapt `srslte/enb_zmq.conf` and `srslte/ue_zmq.conf`

Exact build flags/packages **must be verified before continuing** against current srsRAN_4G docs. The rest of this tutorial assumes the **Docker** method.

---

## 17. ZMQ installation/configuration

Inside `docker_srslte`, ZMQ is already compiled in (`libzmq3-dev` in `srslte/Dockerfile`).

You do **not** install an SDR driver for this lab.

ZMQ wiring comes from the config templates:

**eNB** (`srslte/enb_zmq.conf`):

```ini
[rf]
device_name = zmq
device_args = fail_on_disconnect=true,tx_port=tcp://SRS_ENB_IP:2000,rx_port=tcp://SRS_UE_IP:2001,id=enb,base_srate=23.04e6
```

**UE** (`srslte/ue_zmq.conf`):

```ini
[rf]
device_name = zmq
device_args = tx_port=tcp://SRS_UE_IP:2001,rx_port=tcp://SRS_ENB_IP:2000,id=ue,base_srate=23.04e6
```

`srslte/srslte_init.sh` replaces `SRS_ENB_IP` / `SRS_UE_IP` from `.env`.

With host networking and both set to `10.195.138.30`, ports `2000`/`2001` distinguish eNB vs UE.

---

## 18. srsRAN eNodeB configuration

### 18.1 Config file parameters

**File path:** `srslte/enb_zmq.conf`

| Parameter | Template value | After substitution on PC-1 | Reason |
|-----------|----------------|----------------------------|--------|
| `mcc` | `MCC` | `001` | PLMN |
| `mnc` | `MNC` | `01` | PLMN |
| `mme_addr` | `MME_IP` | **`10.195.138.20`** | reach MME on PC-2 |
| `gtp_bind_addr` | `SRS_ENB_IP` | `10.195.138.30` | local GTP-U bind |
| `s1c_bind_addr` | `SRS_ENB_IP` | `10.195.138.30` | local S1AP bind |
| `device_name` | `zmq` | `zmq` | no SDR |

Relevant block:

```ini
[enb]
enb_id = 0x19B
mcc = MCC
mnc = MNC
mme_addr = MME_IP
gtp_bind_addr = SRS_ENB_IP
s1c_bind_addr = SRS_ENB_IP
s1c_bind_port = 0
n_prb = 50
```

### 18.2 Change compose to host networking (multihost)

Upstream multihost docs show this for `srsenb.yaml`. Apply the **same pattern** to **`srsenb_zmq.yaml`** because your eNB is also on a different PC.

**File path:** `srsenb_zmq.yaml`

**Original (single-host assumption):**

```yaml
    networks:
      default:
        ipv4_address: ${SRS_ENB_IP}
networks:
  default:
    external: true
    name: docker_open5gs_default
```

**Required for PC-1 multihost:**

```yaml
    network_mode: host
```

Remove the `networks:` attachment / external `docker_open5gs_default` dependency (that network exists only on PC-2).

Example service shape:

```yaml
services:
  srsenb_zmq:
    image: docker_srslte
    container_name: srsenb_zmq
    stdin_open: true
    tty: true
    privileged: true
    network_mode: host
    volumes:
      - ./srslte:/mnt/srslte
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    environment:
      - COMPONENT_NAME=enb_zmq
```

**Reason:** with host networking, eNB sockets use PC-1’s real LAN IP, so PC-2 can send GTP-U back to `10.195.138.30`, and eNB can open SCTP to `10.195.138.20:36412`.

---

## 19. srsRAN UE configuration

**File path:** `srslte/ue_zmq.conf`

| Parameter | Template | Required match |
|-----------|----------|----------------|
| `op` | `UE1_OP` | Open5GS OP/OPc pair |
| `k` | `UE1_KI` | Open5GS K |
| `imsi` | `UE1_IMSI` | Open5GS IMSI |
| `apn` | `internet` | Open5GS APN |

```ini
[usim]
mode = soft
algo = milenage
op  = UE1_OP
k    = UE1_KI
imsi = UE1_IMSI
imei = 353490069873319

[nas]
apn = internet
apn_protocol = ipv4
```

### Host networking for UE compose

**File path:** `srsue_zmq.yaml`

Replace Docker-network attachment with:

```yaml
    network_mode: host
```

**Reason:** ZMQ must reach eNB ports on the same host namespace; also simplifies TUN device handling with `privileged` + `NET_ADMIN`.

> Upstream single-host mode places UE on `docker_open5gs_default` at `SRS_UE_IP=172.22.0.34`. That only works when eNB is on the **same** Docker network (typically same PC as EPC). Your eNB is on PC-1, so host networking (or another shared PC-1 network) is required.

---

## 20. Connecting eNodeB on PC-1 to MME on PC-2

### Checklist before start

On **PC-2**:

```bash
docker compose -f 4g-volte-deploy.yaml ps
ss -lntup | grep -E '36412|2152|9999' || true
ss -ln | grep 36412 || true
```

**Expected result:** MME published on host SCTP/36412; SGWU on UDP/2152; WebUI on 9999.

On **PC-1**:

```bash
ping -c 3 10.195.138.20
```

### Start eNB

**Run on:** PC-1  
**Directory:** `~/docker_open5gs`

```bash
set -a
source .env
set +a
docker compose -f srsenb_zmq.yaml up -d && docker container attach srsenb_zmq
```

**Purpose:** launch ZMQ eNB and attach to its console.

**Expected eNB log themes:**

* ZMQ radio initialized
* S1 connected / S1 Setup Response successful toward `10.195.138.20`

**Expected on PC-2 MME logs:**

```bash
docker logs -f mme
```

Look for eNB connection / S1 Setup success from `10.195.138.30`.

**If it fails, check:**

* PC-2 compose port publish uncommented
* PC-1 `.env` `MME_IP=10.195.138.20` (not `172.22.0.9`)
* firewall / UFW
* `modprobe sctp` on both hosts
* Docker SCTP port publishing support on your kernel — **This must be verified before continuing** if SCTP never establishes

### Verify SCTP association

**Run on:** PC-2

```bash
sudo apt install -y lksctp-tools
sudo ss -Slnp | grep 36412 || sudo ss -lnp | grep 36412
docker exec -it mme bash -lc 'ss -Slnp || ss -lnp'
```

**Run on:** PC-1

```bash
sudo tcpdump -ni any sctp
```

**Expected result:** SCTP four-way handshake and ongoing S1AP between `.30` and `.20`.

---

## 21. Connecting UE → eNodeB → EPC

Order matters:

1. EPC+IMS healthy on PC-2
2. Subscriber provisioned
3. eNB S1 connected
4. **Then** start UE

**Run on:** PC-1  
**Directory:** `~/docker_open5gs`

```bash
set -a
source .env
set +a
docker compose -f srsue_zmq.yaml up -d && docker container attach srsue_zmq
```

**Purpose:** start ZMQ UE; it connects I/Q to eNB, camps on cell, performs attach.

**Traffic path:**

```text
UE NAS/RRC  --ZMQ-->  eNB  --S1AP-->  MME  --Diameter-->  HSS
UE IP data  --PDCP--> eNB  --GTP-U--> SGWU --> UPF/ogstun --> NAT/Internet
```

---

## 22. Testing LTE attach

### On UE console (PC-1)

**Expected result:** messages indicating cell found, RRC connected, attach accepted, and a TUN interface address in `192.168.100.0/24`.

Also check:

```bash
docker exec -it srsue_zmq ip addr show
docker exec -it srsue_zmq ip route
```

**Expected result:** `tun_srsue` (or similar) with `192.168.100.x`.

### RRC IDLE after attach is often success

After attach, srsENB may release the radio when its **RRC inactivity timer** expires (often ~30s with no traffic). UE then shows:

```text
Received RRC Connection Release ...
RRC IDLE
```

MME may log `UE Context Release` and start the Mobile Reachable timer. That means **radio idle**, not “detach failed” — the UE can still be EMM-REGISTERED with `192.168.100.x` on `tun_srsue`.

**Prove it before restarting the UE:**

```bash
docker exec -it srsue_zmq ping -c 5 8.8.8.8
```

Ping from IDLE should wake RRC (Service Request) and succeed if user plane is OK.

Worked example of a full successful attach → IDLE log set: [`ATTACH_SUCCESS_WALKTHROUGH.md`](./ATTACH_SUCCESS_WALKTHROUGH.md).  
If release happens in ~1s, attach never gets an IP, or restart never does RACH: [`troubleshoot.md`](./troubleshoot.md).

### On MME / HSS (PC-2)

```bash
docker logs mme 2>&1 | tail -100
docker logs hss 2>&1 | tail -100
```

**Expected result:** authentication success, attach/PDN success for IMSI `001011234567895`.

### On SGWU / UPF

```bash
docker logs sgwu 2>&1 | tail -50
docker logs upf 2>&1 | tail -50
docker exec -it upf ip addr show ogstun
```

**Note:** UPF may log `Invalid packet [IP version:6]` while the session is IPv4-only (`PDN-Type[1]`). That drop is harmless for a basic internet attach.

**If attach fails, check:**

* IMSI/K/OP-OPc mismatch between UE and Open5GS
* APN `internet` missing on subscriber
* S1 not up
* MCC/MNC/TAC mismatch (`TAC=1` in `.env`, `rr_enb_zmq.conf` gets `TAC` substituted)

---

## 23. Testing Internet/data connectivity

**Run on:** PC-1

```bash
docker exec -it srsue_zmq ping -c 3 8.8.8.8
docker exec -it srsue_zmq ping -c 3 1.1.1.1
```

**Purpose:** confirm GTP-U user plane + UPF NAT.

**Expected result:** ICMP replies.

**If it fails, check:**

* `SGWU_ADVERTISE_IP=10.195.138.20` on PC-2
* UDP/2152 published on PC-2
* PC-2 `ip_forward=1`
* UPF container running and `ogstun` exists
* return GTP-U from PC-2 to `10.195.138.30` not blocked by firewall
* capture GTP-U:

```bash
# PC-1
sudo tcpdump -ni any udp port 2152

# PC-2
sudo tcpdump -ni any udp port 2152
```

---

## 24. IMS registration

### What the repo provides

* IMS APN pool + P-CSCF PCO in SMF
* Kamailio P/I/S-CSCF
* pyHSS + IMS DNS
* RTPEngine for media

### What srsUE does by default

* Attaches to **`internet`** APN only (`ue_zmq.conf`)
* Does **not** include a full IMS/VoLTE SIP UA like a commercial phone

### Practical IMS lab paths

1. **Core readiness (always do this):** verify P-CSCF/I-CSCF/S-CSCF/pyHSS/DNS are up on PC-2.
2. **SIP REGISTER test:** use an IMS-capable client that can:
   - use the UE data path, or
   - reach P-CSCF (`172.22.0.21`) via routing that **must be verified** in your topology, or
   - run inside the Docker network on PC-2 for signalling-only tests.
3. **Commercial UE / advanced UE:** when you move beyond ZMQ soft-UE, use the same EPC/IMS provisioning.

### Verify IMS containers

**Run on:** PC-2

```bash
docker compose -f 4g-volte-deploy.yaml ps
docker logs pcscf 2>&1 | tail -50
docker logs icscf 2>&1 | tail -50
docker logs scscf 2>&1 | tail -50
docker logs pyhss 2>&1 | tail -50
docker logs dns 2>&1 | tail -50
```

**Expected result:** Kamailio processes listening; pyHSS API on host `8080`; DNS serving IMS zone.

### Example SIP identities (for an IMS client)

```text
Private ID: 001011234567895@ims.mnc001.mcc001.3gppnetwork.org
Public ID:  sip:9076543210@ims.mnc001.mcc001.3gppnetwork.org
Realm:      ims.mnc001.mcc001.3gppnetwork.org
P-CSCF:     172.22.0.21  (or pcscf.ims.mnc001.mcc001.3gppnetwork.org if DNS works)
```

IMS authentication credentials come from pyHSS AUC (same Ki/OPc/IMSI).

### Diameter Cx check

On PC-2 during REGISTER:

```bash
sudo tcpdump -ni any port 3868 or port 3870 or port 3875
docker logs scscf -f
docker logs pyhss -f
```

**Expected result:** Diameter exchanges between S-CSCF and pyHSS; successful authentication vectors.

---

## 25. Testing SIP/VoLTE

### Signalling test (REGISTER)

Use `sngrep` on PC-2:

```bash
sudo sngrep
# or inside pcscf network namespace:
docker exec -it pcscf bash -lc 'apt-get update && apt-get install -y sngrep; sngrep'
```

**Expected result:** `REGISTER` → `401 Unauthorized` → `REGISTER` (auth) → `200 OK`.

### Call test (INVITE)

Requires two IMS endpoints provisioned in pyHSS/Open5GS. Media flows via RTPEngine (`rtpengine` container). Exact softphone settings beyond P-CSCF/realm/IMPI/IMPU **must be verified** for the client you choose.

### Realistic expectation for this ZMQ lab

| Stage | Expected with srsUE ZMQ |
|-------|-------------------------|
| LTE attach | Yes |
| Internet PDN / ping | Yes |
| IMS containers up | Yes |
| Full VoLTE MO/MT call from srsUE alone | Not guaranteed; needs IMS UA + IMS PDN path verification |

---

## 26. Packet capture and troubleshooting

### Universal status commands

**PC-2:**

```bash
docker ps
docker compose -f 4g-volte-deploy.yaml ps
ip addr
ip route
ss -lntup
ping -c 3 10.195.138.30
```

**PC-1:**

```bash
docker ps
ip addr
ip route
ss -lntup
ping -c 3 10.195.138.20
```

### SCTP / S1AP

```bash
# PC-1 or PC-2
sudo tcpdump -ni any sctp -w s1ap.pcap
# Wireshark: decode as S1AP
```

**Expected:** S1 Setup Request/Response; later Initial UE Message / Attach.

### GTP-U

```bash
sudo tcpdump -ni any udp port 2152 -w gtpu.pcap
```

**Expected:** GTP-U between `10.195.138.30` and `10.195.138.20` after attach/data.

### GTP-C (S11 / S5 mostly internal on PC-2)

```bash
sudo tcpdump -ni docker0 udp port 2123
# or on compose network interface — interface name must be verified with `ip link`
```

### Diameter

```bash
sudo tcpdump -ni any tcp port 3868 or tcp port 3869 or tcp port 3870 or tcp port 3871 or tcp port 3875
```

### SIP

```bash
sudo sngrep
sudo tcpdump -ni any port 5060 or port 4060 or port 6060 -w sip.pcap
```

### Component logs

```bash
docker logs mme
docker logs hss
docker logs sgwu
docker logs smf
docker logs upf
docker logs pcscf
docker logs icscf
docker logs scscf
docker logs pyhss
```

On PC-1, srs logs are volume-mounted:

```bash
tail -f srslte/enb.log
tail -f srslte/ue.log
```

---

## 27. Common errors and fixes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| eNB cannot S1-connect | `MME_IP` still `172.22.0.9` on PC-1 | Set `MME_IP=10.195.138.20` |
| eNB S1 connect fails | ports not published | Uncomment MME `36412/sctp` and SGWU `2152/udp` in `4g-volte-deploy.yaml` |
| Attach OK, no data | `SGWU_ADVERTISE_IP` still Docker IP | Set to `10.195.138.20` |
| Auth fail | K/OP/OPc/IMSI mismatch | Align section 11 values everywhere |
| ZMQ disconnect | UE started before eNB / wrong ZMQ IPs | Start eNB first; both ZMQ IPs `10.195.138.30` with host mode |
| `docker_open5gs_default` missing on PC-1 | copied single-host compose | use `network_mode: host` on eNB/UE |
| SCTP silently fails | UFW / no sctp module / Docker SCTP issues | disable UFW, `modprobe sctp`, verify Docker SCTP publish |
| Containers unhealthy on PC-2 | first-boot DB races | wait; `docker compose ... restart` failed service; check `mysql`/`dns` logs |
| UE ping fails | PC-2 forwarding/NAT/firewall | `sysctl ip_forward=1`, check UPF `ogstun`, capture UDP/2152 |
| IMS REGISTER fails | pyHSS subscriber missing / DNS / unreachable P-CSCF | provision pyHSS; verify DNS; ensure route to `PCSCF_IP` |

---

## 28. Complete startup sequence

### PC-2 first (EPC → IMS → verify)

**Run on:** PC-2  
**Directory:** `~/docker_open5gs`

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo ufw disable
set -a
source .env
set +a
docker compose -f 4g-volte-deploy.yaml up -d
docker compose -f 4g-volte-deploy.yaml ps
curl -I http://10.195.138.20:9999
curl -I http://10.195.138.20:8080/docs/
```

**Successful signs:**

* `mme`, `hss`, `sgwu`, `sgwc`, `smf`, `upf`, `pcscf`, `icscf`, `scscf`, `pyhss`, `dns`, `mysql` are `Up`
* WebUI and pyHSS docs respond
* `ss` shows host listeners for `36412` (SCTP) and `2152` (UDP)

Ensure subscriber exists (section 11) before UE attach.

### PC-1 second (eNB → UE)

**Run on:** PC-1  
**Directory:** `~/docker_open5gs`

```bash
set -a
source .env
set +a

# 1) eNB
docker compose -f srsenb_zmq.yaml up -d
docker logs -f srsenb_zmq
# wait until S1 is up, then Ctrl+C to stop following logs (container keeps running)

# 2) UE
docker compose -f srsue_zmq.yaml up -d
docker logs -f srsue_zmq
```

**Successful signs:**

* eNB: S1 Setup success to `10.195.138.20`
* UE: attach accept + `192.168.100.x` on TUN
* `ping 8.8.8.8` from UE container works

### Optional IMS signalling check

On PC-2, watch:

```bash
docker logs -f pcscf
docker logs -f scscf
docker logs -f pyhss
```

Then run your IMS client REGISTER (section 24–25).

---

## 29. Complete shutdown sequence

### PC-1

**Run on:** PC-1  
**Directory:** `~/docker_open5gs`

```bash
docker compose -f srsue_zmq.yaml down
docker compose -f srsenb_zmq.yaml down
```

**Purpose:** stop UE first, then eNB (clean RF/S1 teardown).

### PC-2

**Run on:** PC-2  
**Directory:** `~/docker_open5gs`

```bash
docker compose -f 4g-volte-deploy.yaml down
```

**Purpose:** stop EPC+IMS.

Data persistence notes:

* MongoDB volume `docker_open5gs_mongodbdata` keeps Open5GS subscribers
* MySQL volume `docker_open5gs_dbdata` keeps IMS DB
* Use `docker compose ... down -v` only if you intentionally want to wipe databases

---

## 30. Final verification checklist

### Networking

- [ ] PC-1 is `10.195.138.30`, PC-2 is `10.195.138.20`
- [ ] Mutual ping works
- [ ] UFW disabled (or equivalent rules allow SCTP/36412 and UDP/2152)
- [ ] PC-2 `net.ipv4.ip_forward=1`

### PC-2 EPC/IMS

- [ ] `.env`: `DOCKER_HOST_IP=10.195.138.20`
- [ ] `.env`: `SGWU_ADVERTISE_IP=10.195.138.20`
- [ ] `4g-volte-deploy.yaml`: MME `36412/sctp` published
- [ ] `4g-volte-deploy.yaml`: SGWU `2152/udp` published
- [ ] `docker compose -f 4g-volte-deploy.yaml ps` healthy
- [ ] WebUI `http://10.195.138.20:9999` works
- [ ] Subscriber IMSI/K/OPc/APNs provisioned
- [ ] pyHSS AUC + IMS subscriber provisioned (for IMS)

### PC-1 RAN/UE

- [ ] `.env`: `MME_IP=10.195.138.20`
- [ ] `.env`: `SRS_ENB_IP=10.195.138.30`, `SRS_UE_IP=10.195.138.30`
- [ ] `srsenb_zmq.yaml` uses `network_mode: host`
- [ ] `srsue_zmq.yaml` uses `network_mode: host`
- [ ] UE IMSI/K/OP match Open5GS
- [ ] eNB S1 connected
- [ ] UE attached and received `192.168.100.x`
- [ ] UE can ping Internet through EPC

### IMS (when testing VoLTE)

- [ ] `pcscf` / `icscf` / `scscf` / `dns` / `pyhss` up
- [ ] IMS identities match MSISDN/IMSI
- [ ] SIP REGISTER reaches P-CSCF and returns `200 OK`
- [ ] Diameter Cx between S-CSCF and pyHSS succeeds

---

## Quick reference — which IP goes in which `.env`

| Variable | PC-2 `.env` | PC-1 `.env` |
|----------|-------------|-------------|
| `DOCKER_HOST_IP` | `10.195.138.20` | `10.195.138.30` |
| `MME_IP` | `172.22.0.9` (container) | **`10.195.138.20` (PC-2 host)** |
| `SGWU_ADVERTISE_IP` | **`10.195.138.20`** | (unused by eNB compose) |
| `SRS_ENB_IP` | unused for EPC-only | `10.195.138.30` |
| `SRS_UE_IP` | unused for EPC-only | `10.195.138.30` |
| `MCC`/`MNC` | `001`/`01` | `001`/`01` |

---

## Source of truth / verification notes

This tutorial is based on the current files in [herlesupreeth/docker_open5gs](https://github.com/herlesupreeth/docker_open5gs), especially:

* `.env`
* `4g-volte-deploy.yaml`
* `srsenb_zmq.yaml` / `srsue_zmq.yaml`
* `srslte/enb_zmq.conf` / `srslte/ue_zmq.conf` / `srslte/srslte_init.sh`
* `mme/mme.yaml`, `sgwu/sgwu.yaml`, `smf/smf_4g.yaml`, `upf/upf.yaml`
* `dns/*`, `pcscf/*`, `icscf/*`, `scscf/*`
* upstream README multihost 4G section

Whenever something depends on your exact NIC names, softphone, or kernel/Docker SCTP behavior, the tutorial marks it as:

> **This must be verified before continuing.**

Do not invent alternate compose service names or IPs; change only the documented multihost parameters and host-network adaptations required for PC-1 ↔ PC-2.

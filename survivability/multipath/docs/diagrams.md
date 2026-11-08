# Black Relay — diagrams

Mermaid sources for how the site box, its modems and the hub connect and work.
They render on GitHub and in VS Code. Companion to
`../../cwwk/docs/Black-Relay-Site-Architecture.pdf` (rendered: `Black-Relay-Diagrams.pdf`) and `../../cwwk/controller/README.md`.

## 1. End to end: every modem, its own carrier, one hub

```mermaid
flowchart TB
  subgraph SITE["CWWK site box"]
    direction LR
    PORTS["4 ports<br/>any cable, any port"] --> EDGE["br-edge<br/>names each modem · caps<br/>6 TLS lanes per modem<br/>glorytun bonding · leak guard"]
    LAN["br-router<br/>site LAN + Wi-Fi 10.40.0.x<br/>services 10.41.0.x"] --> EDGE
  end
  EDGE == "6 lanes" ==> ISP["ISP router"] --> ISPN(["ISP network"])
  EDGE == "6 lanes" ==> SLR["Starlink router"] --> DISH["Dish"] -.-> SAT(["Satellite"]) -.-> POP["Ground station<br/>+ Starlink PoP"]
  EDGE == "6 lanes" ==> SPZ["Spitz 4G/5G"] -.-> TWR["Cell tower"] --> CORE["Carrier core"]
  ISPN --> NET(["Public internet"])
  POP --> NET
  CORE --> NET
  subgraph HUB["BR2026 · Hetzner Helsinki · 89.167.30.202"]
    direction LR
    FW["Hetzner firewall<br/>TCP 80/443 only"] --> CADDY["Caddy :443<br/>/multithread-* → hub lanes<br/>/cwwk/* → site controller<br/>else → Headscale"]
    CADDY --> WST["hub: wstunnel :8080<br/>unwraps each lane"] --> GT["glorytun hub 10.255.1.1<br/>decrypt · reorder (400 ms)"]
    GT --> NAT["NAT exit<br/>89.167.30.202"]
    ID["Headscale · Pocket ID · LLDAP"]
    SF["sf-dev · Sensor Fusion box<br/>tailnet only"]
  end
  NET --> FW
  NAT --> OUT(["websites and services"])
```

## 2. Inside the CWWK: one port bridge

```mermaid
flowchart LR
  subgraph JACKS["Physical ports"]
    N0["nic0"]; N1["nic1"]; N2["nic2"]; N3["nic3"]
  end
  subgraph BR["vmbr10 · VLAN-aware · spanning tree (CWWK is root)"]
    V100["VLAN 100"]; V101["VLAN 101"]; V102["VLAN 102"]; V103["VLAN 103"]
    V40["VLAN 40 · Wi-Fi / site LAN<br/>tagged on every port"]
  end
  N0 -- untagged --> V100
  N1 -- untagged --> V101
  N2 -- untagged --> V102
  N3 -- untagged --> V103
  N0 & N1 & N2 & N3 -. tagged 40 .-> V40
  V100 --> U0["br-edge up0"]
  V101 --> U1["br-edge up1"]
  V102 --> U2["br-edge up2"]
  V103 --> U3["br-edge up3"]
  V40 --> RL["br-router br-lan<br/>10.40.0.1 · DHCP · DNS"]
  RL --- SL["site LAN vmbr1<br/>controller .10 · host .2"]
  RL -- "transit 10.39.0.0/30" --> E["br-edge tr0"]
  E --> T["tunnel br0 → hub"]
```

## 3. What each port becomes

```mermaid
flowchart TD
  P["Cable plugged in"] --> Q1{"br-edge gets an address<br/>(a DHCP server answers)?"}
  Q1 -- yes --> K{"carriers.conf"}
  K -- "dish answers 192.168.100.1:9200<br/>or CGNAT address" --> SL["Starlink · caps 10/150<br/>dish page + app reachable (9200/9201)"]
  K -- "gateway 192.168.9.1" --> SP["Spitz · caps 5/20"]
  K -- "anything else" --> IS["ISP · caps 100/150"]
  SL & SP & IS --> L["6 lanes join the tunnel"]
  P --> W{"tagged VLAN 40 seen?"}
  W -- yes --> AP["Wi-Fi access point on this port<br/>(the Spitz) → site LAN"]
  Q1 -- "no, 45 s after link-up,<br/>and a device keeps asking" --> C["Client port<br/>untagged → VLAN 40 → 10.40.0.x"]
  C -- "a DHCP server appears<br/>or the cable is pulled" --> Q1
  IS -. "every minute: its own check answers now<br/>(Starlink still booting at start)" .-> SL
```

## 4. Packet pipeline: deconstruct, spread, reconstruct

```mermaid
flowchart LR
  subgraph TX["Sender · deconstruct"]
    direction TB
    a1["Inner IP packet<br/>from tun"] --> a2["Assign 64-bit seq #<br/>inside the AEAD"]
    a2 --> a3["FEC encoder<br/>every N packets → XOR parity"]
    a3 --> a4["AEAD encrypt<br/>AEGIS-256 or ChaCha20<br/>monotonic nonce"]
    a4 --> a5["Header protection<br/>mask the timestamp field"]
    a5 --> a6{"Scheduler<br/>GT_SCHED"}
  end
  TX -- "seq 1, 4, 7" --> L1["ISP"]
  TX -- "seq 2, 5, 8" --> L2["Starlink"]
  TX -- "seq 3, 6, 9" --> L3["Spitz"]
  subgraph RX["Receiver · reconstruct"]
    direction TB
    b1["Unmask header"] --> b2["Decrypt + verify MAC<br/>forged → drop"]
    b2 --> b3["Anti-replay window<br/>2048 packets · replay → drop"]
    b3 --> b4["FEC recover<br/>1 lost packet per group"]
    b4 --> b5["Resequencer<br/>hold a gap ≤ GT_RESEQ_MS"]
    b5 --> b6["tun · in order"]
  end
  L1 --> RX
  L2 --> RX
  L3 --> RX
```

## 5. One group, end to end

```mermaid
sequenceDiagram
  participant S as br-edge (sends)
  participant A as ISP ~20 ms
  participant B as Starlink ~45 ms
  participant C as Spitz ~60 ms
  participant R as BR2026 hub (receives)
  participant T as tun → services
  Note over S: FEC group N=4: seq 1-4 plus parity P
  S->>A: seq 1
  S->>B: seq 2
  S->>C: seq 3
  S->>A: seq 4
  S->>B: parity P = 1⊕2⊕3⊕4
  A->>R: seq 1
  R->>T: release 1
  A->>R: seq 4 (overtook 2 and 3)
  Note over R: hold 4, gap at 2
  B->>R: seq 2
  R->>T: release 2
  C--xR: seq 3 lost on Spitz
  B->>R: parity P
  Note over R: rebuild 3 = P⊕1⊕2⊕4<br/>no wait for the deadline
  R->>T: release 3, 4 in order
```

## 6. Resequencer decisions

```mermaid
stateDiagram-v2
  [*] --> Arrived: decrypted data packet
  Arrived --> Dropped: replay, or behind the window
  Arrived --> Released: seq is the next expected
  Arrived --> Held: seq is ahead of a gap
  Held --> Released: gap filled by a late packet or FEC rebuild
  Held --> Skipped: gap older than GT_RESEQ_MS
  Skipped --> Released: missing seq counted lost, later ones flow
  Released --> [*]: written to tun in order
  Dropped --> [*]
```

## 7. Adaptive FEC (GT_FEC=auto; off today, GT_FEC=0)

```mermaid
flowchart LR
  M["Sender reads its own<br/>forward loss once a second<br/>path tx.loss from the stat exchange"] --> D{"forward loss"}
  D -- "under 0.5 %" --> N32["N = 32<br/>~3 % overhead"]
  D -- "under 1 %" --> N16["N = 16<br/>~6 %"]
  D -- "under 3 %" --> N8["N = 8<br/>12.5 %"]
  D -- "under 6 %" --> N4["N = 4<br/>25 %"]
  D -- "6 % or more" --> N2["N = 2<br/>50 %"]
```

## 8. Self-healing

```mermaid
flowchart LR
  A["Cable moved / DHCP change<br/>(port address or gateway changes)"] --> W["uplink watcher<br/>restarts the tunnel"] --> D["br-uplinks re-detects<br/>every port, rewrites caps"]
  B["Some lanes of one modem stuck<br/>(Starlink warm-up)"] --> N["lane nurse: modem can reach the hub?<br/>re-dial just those lanes<br/>backoff 30 s → 5 min"]
  C["Lanes up but no data<br/>(hub stops answering)"] --> G["watchdog: 3 failed pings<br/>→ restart the tunnel"]
  E["Tunnel down"] --> F["fail closed:<br/>site traffic dropped, never sent raw"]
  H["Modem recognised late<br/>(Starlink booting at tunnel start)"] --> R["re-check every minute:<br/>catch-all 'ISP' → real kind,<br/>restart once (max 1 per 5 min)"]
  I["Cable pulled from a modem port<br/>(invisible behind the bridge)"] --> J["re-check ARPs the modem:<br/>2 misses → drop its old lease"]
```

## 9. Remote access to the site controller

```mermaid
sequenceDiagram
  participant U as Browser (anywhere)
  participant C as Caddy · headscale.l8s.dev
  participant H as Hub :8444
  participant K as Controller 10.40.0.10
  participant P as Pocket ID · id.l8s.dev
  U->>C: https://headscale.l8s.dev/cwwk/
  C->>H: /cwwk/* (prefix stripped)
  H->>K: forwarded through the tunnel (from 10.255.1.1 only)
  K-->>U: not signed in → Sign in with Pocket ID
  U->>P: sign in (passkey)
  P-->>K: code → token + groups (checked over TLS)
  K-->>U: session: survivability = admin, headscale-users = view
```

## 10. Many sites, one hub

```mermaid
flowchart LR
  S1["Site cwwk01<br/>6 lanes per modem"] --> C["Caddy :443<br/>/multithread-*"]
  S2["Site 2<br/>lanes per modem"] --> C
  C --> W["hub wstunnel :8080<br/>secret path prefix"]
  W --> T1["glorytun br-cwwk01<br/>10.255.1.1 ⇄ .2"]
  W --> T2["glorytun site 2<br/>10.255.2.1 ⇄ .2"]
  T1 & T2 --> X["NAT exit 89.167.30.202<br/>sites never reach each other"]
```

## 11. Site lock: power-on to unlocked

```mermaid
flowchart TD
  ON["Power on / reboot / Lock"] --> LK["LOCKED<br/>Wi-Fi + LAN addresses, controller page<br/>vault closed · tailnet off · services stopped"]
  LK --> OK1["Reachable while locked:<br/>sign-in at BR2026 (443) · router DNS<br/>modem + dish pages"]
  LK --> U{"Unlock"}
  U -- "USB key BRKEY<br/>plugged into the CWWK" --> V["vault opens<br/>(the key must open it)"]
  U -- "admin password (on site) or Pocket ID (anywhere)<br/>+ vault passphrase" --> V
  V --> OPEN["UNLOCKED<br/>edge gate open · tailnet on<br/>service containers (br-gated) start"]
  OPEN -- "Lock site button" --> LK
  OPEN -- "power cut / reboot" --> LK
  X["5 wrong passphrases"] --> Y["wait 15 minutes"]
```

## 12. Sensor Fusion on BR2026

```mermaid
flowchart LR
  subgraph TN["Tailnet: Sensor Fusion mesh"]
    direction TB
    TAKP["TAK team<br/>laptops · ATAK/iTAK phones"]
    DETL["Detection team<br/>laptops"]
    PIS["Pis / sensors<br/>tag:sensor-fusion"]
  end
  subgraph BR["BR2026 host"]
    subgraph SFD["sf-dev · Sysbox system box · 80 GB disk (all kept, backed up)"]
      direction TB
      DK["its own Docker + compose"]
      subgraph FUS["docker network fusion"]
        MQ["MQTT broker<br/>(teams build)"]
        TS["TAK server<br/>(TAK team builds)"]
        DS["Detection services"]
        BRG["bridges / fusion services"]
      end
      DK --> FUS
    end
  end
  DETL -- "ssh dev@sf-dev · build + run" --> DK
  TAKP -- "ssh dev@sf-dev" --> DK
  DS -- "publish detections" --> MQ
  MQ --> BRG --> TS
  PIS -- "sf-dev:port" --> MQ
  TS -- "sf-dev:port" --> TAKP
```


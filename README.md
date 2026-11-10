# FRR EVPN-VXLAN 實驗教學(L2 VNI 與 L3 VNI)

本教學整理自舊的測試筆記,在「單一台 Linux 主機」上用 docker 建立隔離網路與兩個 privileged FRR 容器,
模擬 Server1 / Server2,實作 BGP EVPN-VXLAN。不需要第二台實體機,也不使用 `--network host`,
不修改主機的 iptables / sysctl / netns。
參考文件:<https://docs.frrouting.org/en/latest/evpn.html>

> 已在容器環境驗證(FRR `frrouting/frr:v8.4.1`):L2 與 L3 實驗皆可建立,BGP 為 Established,type-2/3/5 路由出現,ping 成功。

## 目錄結構

```
FRR_EVPN_Lab/
├── README.md
├── common/
│   ├── daemons          # FRR daemons 設定(bgpd=yes),掛載到容器
│   └── lab.sh           # 建立 / 移除 docker network 與兩個 FRR 容器(up l2|l3、down、status)
├── l2-evpn/
│   ├── server1.sh  server2.sh             # 容器內的 Linux 網路設定
│   └── server1-frr.conf  server2-frr.conf # vtysh 格式的 FRR 設定
└── l3-evpn/
    ├── server1.sh  server2.sh
    └── server1-frr.conf  server2-frr.conf
```

## 1. 概念

- VXLAN / VNI:以 UDP 4789 在 underlay 上封裝 L2 frame,VNI 是 24 bit 的網段識別碼。
- EVPN:用 BGP(address-family `l2vpn evpn`)作為 VXLAN 的控制面,取代資料面的泛洪學習。
- L2 VNI:一個 VNI 對應一個 L2 網段(一個 Linux bridge)。同一網段的主機透過 VXLAN 互通,僅做 L2 橋接。
- L3 VNI(symmetric IRB):每個 VRF 對應一個專用的 L3 VNI(本例 VNI 3000 對應 `vrf1`),用來在不同 VNI(不同子網)之間路由。
  入口 VTEP 先在 VRF 內路由,封裝成 L3 VNI 送到出口 VTEP,出口再於 VRF 內路由到目的子網,所以兩端都做「一次橋接 + 一次路由」,稱為 symmetric。
- Type-2 route(MAC/IP advertisement):通告主機的 MAC(與 IP),取代 MAC 學習。
- Type-3 route(inclusive multicast):通告 VTEP 加入哪些 VNI,用於 BUM 流量的複製清單。
- Type-5 route(IP prefix):通告 VRF 內的 IP 前綴(本例由 `redistribute connected` 加上 `advertise ipv4 unicast` 產生)。
- `nolearning`(vxlan 介面選項):關閉核心對 VXLAN 的資料面 MAC 學習,由 FRR 透過 EVPN 寫入 FDB。
- `neigh_suppress`(bridge_slave 選項):VTEP 本機代答 ARP/ND(依 EVPN 學到的 neighbor),減少 BUM 廣播跨隧道。
- VRF:Linux VRF 是獨立的路由表(本例 table 1100),隔離 tenant 的路由。
- Anycast gateway:兩台 VTEP 的 SVI(`br100`、`br200`)使用相同 IP 與相同 MAC,主機不論在哪台都用同一個閘道。

## 2. 實驗拓樸

```
         docker network evpnlab-net (underlay 10.99.0.0/24)
   +--------------------+                  +--------------------+
   | 容器 evpnlab-s1    |                  | 容器 evpnlab-s2    |
   | (Server1)          |<==== VXLAN =====>| (Server2)          |
   | 10.99.0.11         |   UDP 4789       | 10.99.0.12         |
   | AS 6500 (iBGP)     |                  | AS 6500 (iBGP)     |
   +--------------------+                  +--------------------+

[L2 實驗]  只有 VNI 100
  host1 10.0.0.1/24 -- br100/vxlan100 ==== vxlan100/br100 -- host1 10.0.0.2/24

[L3 實驗]  vrf1 + L3 VNI 3000
  Server1                                          Server2
  host1 10.0.0.1/24 -- br100 (10.0.0.254) -+       +- br100 (10.0.0.254) -- host1 10.0.0.2/24
                       vxlan100            |       |  vxlan100
  host2 11.0.0.1/24 -- br200 (11.0.0.254) -+- vrf1 -+- br200 (11.0.0.254) -- host2 11.0.0.2/24
                       vxlan200            |       |  vxlan200
                       br3000/vxlan3000 ===+=======+== br3000/vxlan3000   (L3 VNI 3000)
```

host1 / host2 是各容器內的 netns,由 `server*.sh` 建立。

## 3. 前置需求

- 一台 Linux 主機,已安裝 docker(可執行 `docker` 指令的使用者即可,不需要 sudo 修改主機網路)。
- 映像 `frrouting/frr:v8.4.1`(首次執行 `docker pull frrouting/frr:v8.4.1`,或由 `docker run` 自動拉取)。
  可用環境變數 `FRR_IMAGE` 覆寫。
- underlay 網段預設 `10.99.0.0/24`,需與主機既有 docker network 不衝突;可用 `SUBNET`、`S1_IP`、`S2_IP` 覆寫,
  但 `server*-frr.conf` 內的 router-id 與 neighbor 也要同步修改。
- 同一時間只能執行一組實驗(L2 或 L3),`lab.sh up` 會先移除上一次的實驗資源。
- 本實驗只會建立、刪除名稱前綴為 `evpnlab-` 的容器與 network,不會動到主機上其他資源。

## 4. 步驟:L2 EVPN(VNI 100)

```bash
cd FRR_EVPN_Lab
./common/lab.sh up l2
```

`lab.sh up l2` 會:

1. 建立 docker network `evpnlab-net` 與容器 `evpnlab-s1`(10.99.0.11)、`evpnlab-s2`(10.99.0.12)。
2. 在各容器內執行 `l2-evpn/server1.sh` / `server2.sh`:建立 netns `host1`、`vxlan100`(`nolearning`)、`br100`,並把 host 接上 bridge。
3. 用 `vtysh -f` 載入 `server1-frr.conf` / `server2-frr.conf`:`router bgp 6500`、互為 neighbor、
   `l2vpn evpn` 下 `neighbor ... activate` 與 `advertise-all-vni`。

接著依第 6 節驗證,並執行:

```bash
docker exec evpnlab-s1 ip netns exec host1 ping -c 3 10.0.0.2
```

## 5. 步驟:L3 EVPN(VNI 100/200 + L3 VNI 3000)

```bash
cd FRR_EVPN_Lab
./common/lab.sh up l3
```

`server1.sh` / `server2.sh` 的內容(腳本內有逐步註解):

- 設定 `net.ipv4.ip_forward=1` 與 `rp_filter=0`(只作用於容器的網路命名空間)。
- 建立 `vrf1`(table 1100)。
- 對 VNI 100、200、3000 各建立 `vxlan${vni}` 與 `br${vni}`,bridge 掛到 `vrf1`,vxlan 設 `neigh_suppress on learning off`。
- 建立 netns `host1`(接 `br100`)、`host2`(接 `br200`)。
- 在 `br100`、`br200` 設相同 MAC `02:00:00:00:00:fe` 與閘道 IP `10.0.0.254/24`、`11.0.0.254/24`。

FRR 設定重點:

- `vrf vrf1` / `vni 3000`:把 VRF 對應到 L3 VNI。
- `advertise-all-vni`:通告所有本機 L2 VNI。
- `advertise-svi-ip`:通告 SVI 的 IP/MAC。
- `router bgp 6500 vrf vrf1` 中 `redistribute connected` 與 `advertise ipv4 unicast`:把 vrf1 的直連網段以 type-5 通告。

測試步驟:

1. 同網段(L2 VNI):

   ```bash
   docker exec evpnlab-s1 ip netns exec host1 ping -c 3 10.0.0.2
   docker exec evpnlab-s2 ip netns exec host2 ping -c 3 11.0.0.1
   ```

2. 跨網段前,先讓每台 host 各 ping 自己的 gateway(每台 Server、每個 host 都要做):

   ```bash
   for s in s1 s2; do
       docker exec evpnlab-$s ip netns exec host1 ping -c 1 10.0.0.254
       docker exec evpnlab-$s ip netns exec host2 ping -c 1 11.0.0.254
   done
   ```

   原因:vxlan 介面設了 `neigh_suppress on`,VTEP 不再把 ARP 洪泛到對端。遠端主機若從未送過封包,
   EVPN 就沒有該主機的 type-2(MAC+IP)route,本機不知道它的 IP 與 MAC,第一次跨網段 ping 會 100% 失敗(實測如此)。
   host ping gateway 會讓所屬 VTEP 學到該主機的 IP/MAC 並以 type-2 通告,之後 `show ip route vrf vrf1` 才會出現對端 /32 路由。

3. 跨網段(經 L3 VNI 3000):

   ```bash
   docker exec evpnlab-s1 ip netns exec host1 ping -c 3 11.0.0.2
   docker exec evpnlab-s2 ip netns exec host2 ping -c 3 10.0.0.1
   ```

關於 type-5:本拓樸兩端都擁有相同的 SVI 網段(10.0.0.0/24、11.0.0.0/24),所以收到的 type-5 前綴與本機 connected 路由相同,
本機的 connected 路由優先。實際跨 VTEP 的轉送走的是 type-2 產生的 /32 路由(`B>* 10.0.0.2/32 ... br3000 onlink`),
type-5 只是被通告出來,並未用來轉送。若要讓 type-5 真正派上用場,需讓兩端使用不同的子網。

## 6. 驗證指令

Linux 側(在容器內執行):

```bash
docker exec evpnlab-s1 bridge fdb show dev vxlan100 | grep dst  # 應看到由 EVPN 寫入、指向對端 underlay IP 的 FDB
docker exec evpnlab-s1 ip -d link show vxlan100                 # 確認 nolearning、local、dstport 4789
docker exec evpnlab-s1 ip netns exec host1 ip route             # host 的預設路由
```

FRR 側(先進入 `docker exec -it evpnlab-s1 vtysh`,或用 `docker exec evpnlab-s1 vtysh -c '...'`):

```
show bgp l2vpn evpn summary      # neighbor 應為 Established
show bgp l2vpn evpn route        # type-2 / type-3 / type-5
show evpn vni                    # 本機 VNI 清單
show evpn mac vni 100            # VNI 100 學到的 MAC
show evpn arp-cache vni 100      # VNI 100 學到的 ARP(local / remote)
show vrf                         # (L3) VRF 清單
show vrf vni                     # (L3) VRF 與 L3 VNI 3000 的對應
show ip route vrf vrf1           # (L3) 應有對端的 10.0.0.x/32、11.0.0.x/32 路由
show bgp vrf vrf1 ipv4 unicast   # (L3) vrf1 的 BGP 路由,可看到 /24(本機與 type-5)與對端 /32(type-2)
```

## 7. 注意事項(相對於原始筆記的修正)

1. router-id 與 neighbor 寫反:原筆記 Server1 的 router-id 寫對端 IP、neighbor 寫自己(Server2 則相反)。
   已修正:各端 router-id 為自己的 IP,neighbor 為對端 IP。
2. Server2 的 for 迴圈原本只建 `100 3000`,漏了 `200`,導致 `br200` 不存在、接 `h2-ovs-bgp` 失敗。已改為 `100 200 3000`。
3. Server2 host2 的 default route 原本誤寫 `via 10.0.0.254`,已改為 `via 11.0.0.254`。Server2 原本也沒設定 `br100`/`br200` 的閘道 IP,已補上。
   兩端採用相同的 anycast gateway(`10.0.0.254/24`、`11.0.0.254/24`),並用 `ip link set ... address 02:00:00:00:00:fe` 指定相同 MAC。
   anycast gateway 需要相同 MAC,否則主機搬到另一台時 ARP 快取中的閘道 MAC 會失效。
4. 原筆記混用已淘汰的 `ifconfig`、`brctl`,腳本一律改用 iproute2:
   - `brctl addbr/addif/stp` 對應 `ip link add ... type bridge`、`ip link set ... master ...`、`stp_state 0`。
   - `ifconfig` 對應 `ip link set ... up`、`ip addr add`。
5. L3 範例需要 `net.ipv4.ip_forward=1`,否則無法跨網段轉發。
   `rp_filter=0` 為依評估加入的選項:symmetric IRB 的回程封包從 L3 VNI 進入,嚴格反向路徑檢查可能丟包。
   預設關閉,可用 `RELAX_RP_FILTER=0` 取消。這些 sysctl 只影響容器,不影響主機。
6. 腳本皆使用 `set -euo pipefail`。`server*.sh` 不是冪等的,重跑請先 `lab.sh down`(`lab.sh up` 會自動先清理)。
7. `daemons` 檔必須設 `bgpd=yes`(zebra 會一併啟動)。容器內 FRR 設定不會保留,重建容器後需重新套用(`lab.sh up` 會自動處理)。
8. iBGP 與 eBGP:本例兩端同為 AS 6500(iBGP),不需要 `no bgp ebgp-requires-policy`。只有改用 eBGP(兩端 AS 不同)時才需加上。
9. 使用 anycast gateway(兩端相同 IP/MAC)同時開啟 `advertise-svi-ip`,實測在此拓撲沒有出現重複 IP/MAC 的異常。
10. 在 netns 內的 bridge 設 `stp_state 0` 時,容器內可能出現 "STP does not work in non-root netns" 警告,無害。

## 8. 疑難排解

- BGP 不是 Established:`docker exec evpnlab-s1 ping -c1 10.99.0.12` 確認 underlay 互通,
  `docker exec evpnlab-s1 vtysh -c 'show bgp summary'`,以及 router-id / neighbor 沒有寫反。
- `show bgp l2vpn evpn route` 是空的:確認有 `advertise-all-vni`,且 `vxlan` 與 `br` 介面為 up。
- `show evpn vni` 看不到 VNI:確認 vxlan 介面的 `local` 是容器 IP、zebra 與 bgpd 有啟動(`docker logs evpnlab-s1`)。
- 跨網段 ping 不通:先依第 5 節讓各 host ping 自己的 gateway;再檢查 `show vrf vni` 是否有 3000、`show ip route vrf vrf1` 是否有對端 /32 路由。
- `lab.sh up` 建立 network 失敗:`10.99.0.0/24` 可能與既有網段衝突,改用 `SUBNET` 等環境變數(見第 3 節)。
- 重做實驗:直接重跑 `./common/lab.sh up l2|l3`。

## 9. 清理

```bash
./common/lab.sh down
```

只會移除容器 `evpnlab-s1`、`evpnlab-s2` 與 docker network `evpnlab-net`(網路物件隨容器一併消失),
不會動到主機上其他容器、network 與服務。可重複執行。用 `./common/lab.sh status` 檢查是否仍有殘留。
若不再使用,可另行 `docker rmi frrouting/frr:v8.4.1` 移除映像。

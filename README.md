# FRR EVPN-VXLAN 实验教学(L2 VNI 与 L3 VNI)

本教学整理自旧的测试笔记,在「单一台 Linux 主机」上用 docker 创建隔离网络与两个 privileged FRR 容器,
仿真 Server1 / Server2,实作 BGP EVPN-VXLAN。不需要第二台实体机,也不使用 `--network host`,
不修改主机的 iptables / sysctl / netns。
参考文档:<https://docs.frrouting.org/en/latest/evpn.html>

> 已在容器环境验证(FRR `frrouting/frr:v8.4.1`):L2 与 L3 实验皆可创建,BGP 为 Established,type-2/3/5 路由出现,ping 成功。

## 目录结构

```
FRR_EVPN_Lab/
├── README.md
├── common/
│   ├── daemons          # FRR daemons 配置(bgpd=yes),挂载到容器
│   └── lab.sh           # 创建 / 移除 docker network 与两个 FRR 容器(up l2|l3、down、status)
├── l2-evpn/
│   ├── server1.sh  server2.sh             # 容器内的 Linux 网络配置
│   └── server1-frr.conf  server2-frr.conf # vtysh 格式的 FRR 配置
└── l3-evpn/
    ├── server1.sh  server2.sh
    └── server1-frr.conf  server2-frr.conf
```

## 1. 概念

- VXLAN / VNI:以 UDP 4789 在 underlay 上封装 L2 frame,VNI 是 24 bit 的网段识别码。
- EVPN:用 BGP(address-family `l2vpn evpn`)作为 VXLAN 的控制面,取代数据面的泛洪学习。
- L2 VNI:一个 VNI 对应一个 L2 网段(一个 Linux bridge)。同一网段的主机通过 VXLAN 互通,仅做 L2 桥接。
- L3 VNI(symmetric IRB):每个 VRF 对应一个专用的 L3 VNI(本例 VNI 3000 对应 `vrf1`),用来在不同 VNI(不同子网)之间路由。
  入口 VTEP 先在 VRF 内路由,封装成 L3 VNI 送到出口 VTEP,出口再于 VRF 内路由到目的子网,所以两端都做「一次桥接 + 一次路由」,称为 symmetric。
- Type-2 route(MAC/IP advertisement):通告主机的 MAC(与 IP),取代 MAC 学习。
- Type-3 route(inclusive multicast):通告 VTEP 加入哪些 VNI,用于 BUM 流量的拷贝清单。
- Type-5 route(IP prefix):通告 VRF 内的 IP 前缀(本例由 `redistribute connected` 加上 `advertise ipv4 unicast` 产生)。
- `nolearning`(vxlan 接口选项):关闭内核对 VXLAN 的数据面 MAC 学习,由 FRR 通过 EVPN 写入 FDB。
- `neigh_suppress`(bridge_slave 选项):VTEP 本机代答 ARP/ND(依 EVPN 学到的 neighbor),减少 BUM 广播跨隧道。
- VRF:Linux VRF 是独立的路由表(本例 table 1100),隔离 tenant 的路由。
- Anycast gateway:两台 VTEP 的 SVI(`br100`、`br200`)使用相同 IP 与相同 MAC,主机不论在哪台都用同一个闸道。

## 2. 实验拓朴

```
         docker network evpnlab-net (underlay 10.99.0.0/24)
   +--------------------+                  +--------------------+
   | 容器 evpnlab-s1    |                  | 容器 evpnlab-s2    |
   | (Server1)          |<==== VXLAN =====>| (Server2)          |
   | 10.99.0.11         |   UDP 4789       | 10.99.0.12         |
   | AS 6500 (iBGP)     |                  | AS 6500 (iBGP)     |
   +--------------------+                  +--------------------+

[L2 实验]  只有 VNI 100
  host1 10.0.0.1/24 -- br100/vxlan100 ==== vxlan100/br100 -- host1 10.0.0.2/24

[L3 实验]  vrf1 + L3 VNI 3000
  Server1                                          Server2
  host1 10.0.0.1/24 -- br100 (10.0.0.254) -+       +- br100 (10.0.0.254) -- host1 10.0.0.2/24
                       vxlan100            |       |  vxlan100
  host2 11.0.0.1/24 -- br200 (11.0.0.254) -+- vrf1 -+- br200 (11.0.0.254) -- host2 11.0.0.2/24
                       vxlan200            |       |  vxlan200
                       br3000/vxlan3000 ===+=======+== br3000/vxlan3000   (L3 VNI 3000)
```

host1 / host2 是各容器内的 netns,由 `server*.sh` 创建。

## 3. 前置需求

- 一台 Linux 主机,已安装 docker(可运行 `docker` 指令的用户即可,不需要 sudo 修改主机网络)。
- 映像 `frrouting/frr:v8.4.1`(首次运行 `docker pull frrouting/frr:v8.4.1`,或由 `docker run` 自动拉取)。
  可用环境变量 `FRR_IMAGE` 覆写。
- underlay 网段缺省 `10.99.0.0/24`,需与主机既有 docker network 不冲突;可用 `SUBNET`、`S1_IP`、`S2_IP` 覆写,
  但 `server*-frr.conf` 内的 router-id 与 neighbor 也要同步修改。
- 同一时间只能运行一组实验(L2 或 L3),`lab.sh up` 会先移除上一次的实验资源。
- 本实验只会创建、删除名称前缀为 `evpnlab-` 的容器与 network,不会动到主机上其他资源。

## 4. 步骤:L2 EVPN(VNI 100)

```bash
cd FRR_EVPN_Lab
./common/lab.sh up l2
```

`lab.sh up l2` 会:

1. 创建 docker network `evpnlab-net` 与容器 `evpnlab-s1`(10.99.0.11)、`evpnlab-s2`(10.99.0.12)。
2. 在各容器内运行 `l2-evpn/server1.sh` / `server2.sh`:创建 netns `host1`、`vxlan100`(`nolearning`)、`br100`,并把 host 接上 bridge。
3. 用 `vtysh -f` 加载 `server1-frr.conf` / `server2-frr.conf`:`router bgp 6500`、互为 neighbor、
   `l2vpn evpn` 下 `neighbor ... activate` 与 `advertise-all-vni`。

接着依第 6 节验证,并运行:

```bash
docker exec evpnlab-s1 ip netns exec host1 ping -c 3 10.0.0.2
```

## 5. 步骤:L3 EVPN(VNI 100/200 + L3 VNI 3000)

```bash
cd FRR_EVPN_Lab
./common/lab.sh up l3
```

`server1.sh` / `server2.sh` 的内容(脚本内有逐步注解):

- 配置 `net.ipv4.ip_forward=1` 与 `rp_filter=0`(只作用于容器的网络命名空间)。
- 创建 `vrf1`(table 1100)。
- 对 VNI 100、200、3000 各创建 `vxlan${vni}` 与 `br${vni}`,bridge 挂到 `vrf1`,vxlan 设 `neigh_suppress on learning off`。
- 创建 netns `host1`(接 `br100`)、`host2`(接 `br200`)。
- 在 `br100`、`br200` 设相同 MAC `02:00:00:00:00:fe` 与闸道 IP `10.0.0.254/24`、`11.0.0.254/24`。

FRR 配置重点:

- `vrf vrf1` / `vni 3000`:把 VRF 对应到 L3 VNI。
- `advertise-all-vni`:通告所有本机 L2 VNI。
- `advertise-svi-ip`:通告 SVI 的 IP/MAC。
- `router bgp 6500 vrf vrf1` 中 `redistribute connected` 与 `advertise ipv4 unicast`:把 vrf1 的直连网段以 type-5 通告。

测试步骤:

1. 同网段(L2 VNI):

   ```bash
   docker exec evpnlab-s1 ip netns exec host1 ping -c 3 10.0.0.2
   docker exec evpnlab-s2 ip netns exec host2 ping -c 3 11.0.0.1
   ```

2. 跨网段前,先让每台 host 各 ping 自己的 gateway(每台 Server、每个 host 都要做):

   ```bash
   for s in s1 s2; do
       docker exec evpnlab-$s ip netns exec host1 ping -c 1 10.0.0.254
       docker exec evpnlab-$s ip netns exec host2 ping -c 1 11.0.0.254
   done
   ```

   原因:vxlan 接口设了 `neigh_suppress on`,VTEP 不再把 ARP 洪泛到对端。远程主机若从未送过封包,
   EVPN 就没有该主机的 type-2(MAC+IP)route,本机不知道它的 IP 与 MAC,第一次跨网段 ping 会 100% 失败(实测如此)。
   host ping gateway 会让所属 VTEP 学到该主机的 IP/MAC 并以 type-2 通告,之后 `show ip route vrf vrf1` 才会出现对端 /32 路由。

3. 跨网段(经 L3 VNI 3000):

   ```bash
   docker exec evpnlab-s1 ip netns exec host1 ping -c 3 11.0.0.2
   docker exec evpnlab-s2 ip netns exec host2 ping -c 3 10.0.0.1
   ```

关于 type-5:本拓朴两端都拥有相同的 SVI 网段(10.0.0.0/24、11.0.0.0/24),所以收到的 type-5 前缀与本机 connected 路由相同,
本机的 connected 路由优先。实际跨 VTEP 的转送走的是 type-2 产生的 /32 路由(`B>* 10.0.0.2/32 ... br3000 onlink`),
type-5 只是被通告出来,并未用来转送。若要让 type-5 真正派上用场,需让两端使用不同的子网。

## 6. 验证指令

Linux 侧(在容器内运行):

```bash
docker exec evpnlab-s1 bridge fdb show dev vxlan100 | grep dst  # 应看到由 EVPN 写入、指向对端 underlay IP 的 FDB
docker exec evpnlab-s1 ip -d link show vxlan100                 # 确认 nolearning、local、dstport 4789
docker exec evpnlab-s1 ip netns exec host1 ip route             # host 的缺省路由
```

FRR 侧(先进入 `docker exec -it evpnlab-s1 vtysh`,或用 `docker exec evpnlab-s1 vtysh -c '...'`):

```
show bgp l2vpn evpn summary      # neighbor 应为 Established
show bgp l2vpn evpn route        # type-2 / type-3 / type-5
show evpn vni                    # 本机 VNI 清单
show evpn mac vni 100            # VNI 100 学到的 MAC
show evpn arp-cache vni 100      # VNI 100 学到的 ARP(local / remote)
show vrf                         # (L3) VRF 清单
show vrf vni                     # (L3) VRF 与 L3 VNI 3000 的对应
show ip route vrf vrf1           # (L3) 应有对端的 10.0.0.x/32、11.0.0.x/32 路由
show bgp vrf vrf1 ipv4 unicast   # (L3) vrf1 的 BGP 路由,可看到 /24(本机与 type-5)与对端 /32(type-2)
```

## 7. 注意事项(相对于原始笔记的修正)

1. router-id 与 neighbor 写反:原笔记 Server1 的 router-id 写对端 IP、neighbor 写自己(Server2 则相反)。
   已修正:各端 router-id 为自己的 IP,neighbor 为对端 IP。
2. Server2 的 for 循环原本只建 `100 3000`,漏了 `200`,导致 `br200` 不存在、接 `h2-ovs-bgp` 失败。已改为 `100 200 3000`。
3. Server2 host2 的 default route 原本误写 `via 10.0.0.254`,已改为 `via 11.0.0.254`。Server2 原本也没配置 `br100`/`br200` 的闸道 IP,已补上。
   两端采用相同的 anycast gateway(`10.0.0.254/24`、`11.0.0.254/24`),并用 `ip link set ... address 02:00:00:00:00:fe` 指定相同 MAC。
   anycast gateway 需要相同 MAC,否则主机搬到另一台时 ARP 缓存中的闸道 MAC 会失效。
4. 原笔记混用已淘汰的 `ifconfig`、`brctl`,脚本一律改用 iproute2:
   - `brctl addbr/addif/stp` 对应 `ip link add ... type bridge`、`ip link set ... master ...`、`stp_state 0`。
   - `ifconfig` 对应 `ip link set ... up`、`ip addr add`。
5. L3 范例需要 `net.ipv4.ip_forward=1`,否则无法跨网段转发。
   `rp_filter=0` 为依评估加入的选项:symmetric IRB 的回程封包从 L3 VNI 进入,严格反向路径检查可能丢包。
   缺省关闭,可用 `RELAX_RP_FILTER=0` 取消。这些 sysctl 只影响容器,不影响主机。
6. 脚本皆使用 `set -euo pipefail`。`server*.sh` 不是幂等的,重跑请先 `lab.sh down`(`lab.sh up` 会自动先清理)。
7. `daemons` 档必须设 `bgpd=yes`(zebra 会一并启动)。容器内 FRR 配置不会保留,重建容器后需重新套用(`lab.sh up` 会自动处理)。
8. iBGP 与 eBGP:本例两端同为 AS 6500(iBGP),不需要 `no bgp ebgp-requires-policy`。只有改用 eBGP(两端 AS 不同)时才需加上。
9. 使用 anycast gateway(两端相同 IP/MAC)同时打开 `advertise-svi-ip`,实测在此拓扑没有出现重复 IP/MAC 的异常。
10. 在 netns 内的 bridge 设 `stp_state 0` 时,容器内可能出现 "STP does not work in non-root netns" 警告,无害。

## 8. 疑难排解

- BGP 不是 Established:`docker exec evpnlab-s1 ping -c1 10.99.0.12` 确认 underlay 互通,
  `docker exec evpnlab-s1 vtysh -c 'show bgp summary'`,以及 router-id / neighbor 没有写反。
- `show bgp l2vpn evpn route` 是空的:确认有 `advertise-all-vni`,且 `vxlan` 与 `br` 接口为 up。
- `show evpn vni` 看不到 VNI:确认 vxlan 接口的 `local` 是容器 IP、zebra 与 bgpd 有启动(`docker logs evpnlab-s1`)。
- 跨网段 ping 不通:先依第 5 节让各 host ping 自己的 gateway;再检查 `show vrf vni` 是否有 3000、`show ip route vrf vrf1` 是否有对端 /32 路由。
- `lab.sh up` 创建 network 失败:`10.99.0.0/24` 可能与既有网段冲突,改用 `SUBNET` 等环境变量(见第 3 节)。
- 重做实验:直接重跑 `./common/lab.sh up l2|l3`。

## 9. 清理

```bash
./common/lab.sh down
```

只会移除容器 `evpnlab-s1`、`evpnlab-s2` 与 docker network `evpnlab-net`(网络对象随容器一并消失),
不会动到主机上其他容器、network 与服务。可重复运行。用 `./common/lab.sh status` 检查是否仍有残留。
若不再使用,可另行 `docker rmi frrouting/frr:v8.4.1` 移除映像。

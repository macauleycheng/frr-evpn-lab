#!/usr/bin/env bash
# L3 EVPN-VXLAN(symmetric IRB)實驗:Server1 的 Linux 網路設定
# 全部使用 iproute2(ip / bridge),不使用已淘汰的 ifconfig / brctl。
# 用法:由 common/lab.sh up 在容器 evpnlab-s1 內自動執行(容器內為 root,重跑請先 lab.sh down)
# 可用環境變數覆寫:LOCAL_IP、HOST1_CIDR、HOST2_CIDR、GW1_CIDR、GW2_CIDR、GW_MAC、RELAX_RP_FILTER
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-10.99.0.11}"     # 容器 underlay IP
HOST1_CIDR="${HOST1_CIDR:-10.0.0.1/24}"   # host1(接 VNI 100)
HOST2_CIDR="${HOST2_CIDR:-11.0.0.1/24}"   # host2(接 VNI 200)
GW1_CIDR="${GW1_CIDR:-10.0.0.254/24}"     # br100 的 SVI 閘道(兩台相同 = anycast gateway)
GW2_CIDR="${GW2_CIDR:-11.0.0.254/24}"     # br200 的 SVI 閘道
GW_MAC="${GW_MAC:-02:00:00:00:00:fe}"     # 兩台必須使用相同的閘道 MAC
RELAX_RP_FILTER="${RELAX_RP_FILTER:-1}"   # 1 = 將 rp_filter 設為 0(見下方說明)

VRF_NAME=vrf1
VRF_TABLE=1100
L2_VNIS="100 200"
L3_VNI=3000

if [ "$(id -u)" -ne 0 ]; then
    echo "請以 root 執行(容器內預設為 root)" >&2
    exit 1
fi

# 用途:建立一台模擬主機(netns + veth),並把 veth 另一端接到指定 bridge
setup_host() {
    local ns=$1 veth=$2 peer=$3 cidr=$4 gw=$5 br=$6
    ip link add "${veth}" type veth peer name "${peer}"
    ip link set "${peer}" up
    ip netns add "${ns}"
    ip link set "${veth}" netns "${ns}"
    ip netns exec "${ns}" ip link set lo up
    ip netns exec "${ns}" ip link set "${veth}" up
    ip netns exec "${ns}" ip addr add "${cidr}" dev "${veth}"
    ip netns exec "${ns}" ip route add default via "${gw}"
    ip link set "${peer}" master "${br}"
}

# 1. sysctl(僅作用於本容器的網路命名空間,不影響主機)
#    ip_forward=1:跨 VNI(10.0.0.0/24 <-> 11.0.0.0/24)需要主機做三層轉發。
sysctl -w net.ipv4.ip_forward=1 >/dev/null
#    rp_filter=0(可選):symmetric IRB 的回程封包會從 vxlan3000/br3000 進入 vrf1,
#    嚴格反向路徑檢查(rp_filter=1)可能因來源路由不是由該介面進入而丟棄封包。
#    實驗環境關閉較單純;若不需要可設 RELAX_RP_FILTER=0,出現不通再開啟。
if [ "${RELAX_RP_FILTER}" = "1" ]; then
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
fi

# 2. 建立 VRF(tenant 的路由表,table 1100)
ip link add ${VRF_NAME} type vrf table ${VRF_TABLE}
ip link set ${VRF_NAME} up

# 3. 每個 VNI 建立 vxlan + bridge:100/200 為 L2 VNI,3000 為 L3 VNI(僅用於 VRF 之間承載路由)
#    - nolearning / learning off:不靠資料面學 MAC,全由 EVPN 控制面提供
#    - neigh_suppress on:本機回應 ARP/ND,減少 BUM 流量
#    - addrgenmode none:不自動產生 IPv6 link-local 位址
for vni in ${L2_VNIS} ${L3_VNI}; do
    ip link add vxlan${vni} type vxlan id ${vni} dstport 4789 local "${LOCAL_IP}" nolearning
    ip link add br${vni} type bridge
    ip link set br${vni} master ${VRF_NAME} addrgenmode none
    ip link set vxlan${vni} master br${vni} addrgenmode none
    ip link set vxlan${vni} type bridge_slave neigh_suppress on learning off
    ip link set up dev br${vni}
    ip link set up dev vxlan${vni}
done

# 4. 建立模擬主機並接入對應的 L2 網段
setup_host host1 h1 h1-ovs-bgp "${HOST1_CIDR}" "${GW1_CIDR%/*}" br100
setup_host host2 h2 h2-ovs-bgp "${HOST2_CIDR}" "${GW2_CIDR%/*}" br200

# 5. SVI 閘道(anycast gateway):兩台設定相同 IP 與相同 MAC,主機不論接在哪台都能用同一閘道
ip link set br100 address "${GW_MAC}"
ip link set br200 address "${GW_MAC}"
ip addr add "${GW1_CIDR}" dev br100
ip addr add "${GW2_CIDR}" dev br200

echo "Server1 L3 網路設定完成。接著由 lab.sh 套用 server1-frr.conf。"

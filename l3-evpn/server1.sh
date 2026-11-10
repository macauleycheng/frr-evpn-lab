#!/usr/bin/env bash
# L3 EVPN-VXLAN(symmetric IRB)实验:Server1 的 Linux 网络配置
# 全部使用 iproute2(ip / bridge),不使用已淘汰的 ifconfig / brctl。
# 用法:由 common/lab.sh up 在容器 evpnlab-s1 内自动运行(容器内为 root,重跑请先 lab.sh down)
# 可用环境变量覆写:LOCAL_IP、HOST1_CIDR、HOST2_CIDR、GW1_CIDR、GW2_CIDR、GW_MAC、RELAX_RP_FILTER
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-10.99.0.11}"     # 容器 underlay IP
HOST1_CIDR="${HOST1_CIDR:-10.0.0.1/24}"   # host1(接 VNI 100)
HOST2_CIDR="${HOST2_CIDR:-11.0.0.1/24}"   # host2(接 VNI 200)
GW1_CIDR="${GW1_CIDR:-10.0.0.254/24}"     # br100 的 SVI 闸道(两台相同 = anycast gateway)
GW2_CIDR="${GW2_CIDR:-11.0.0.254/24}"     # br200 的 SVI 闸道
GW_MAC="${GW_MAC:-02:00:00:00:00:fe}"     # 两台必须使用相同的闸道 MAC
RELAX_RP_FILTER="${RELAX_RP_FILTER:-1}"   # 1 = 将 rp_filter 设为 0(见下方说明)

VRF_NAME=vrf1
VRF_TABLE=1100
L2_VNIS="100 200"
L3_VNI=3000

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 运行(容器内缺省为 root)" >&2
    exit 1
fi

# 用途:创建一台仿真主机(netns + veth),并把 veth 另一端接到指定 bridge
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

# 1. sysctl(仅作用于本容器的网络命名空间,不影响主机)
#    ip_forward=1:跨 VNI(10.0.0.0/24 <-> 11.0.0.0/24)需要主机做三层转发。
sysctl -w net.ipv4.ip_forward=1 >/dev/null
#    rp_filter=0(可选):symmetric IRB 的回程封包会从 vxlan3000/br3000 进入 vrf1,
#    严格反向路径检查(rp_filter=1)可能因来源路由不是由该接口进入而丢弃封包。
#    实验环境关闭较单纯;若不需要可设 RELAX_RP_FILTER=0,出现不通再打开。
if [ "${RELAX_RP_FILTER}" = "1" ]; then
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
fi

# 2. 创建 VRF(tenant 的路由表,table 1100)
ip link add ${VRF_NAME} type vrf table ${VRF_TABLE}
ip link set ${VRF_NAME} up

# 3. 每个 VNI 创建 vxlan + bridge:100/200 为 L2 VNI,3000 为 L3 VNI(仅用于 VRF 之间承载路由)
#    - nolearning / learning off:不靠数据面学 MAC,全由 EVPN 控制面提供
#    - neigh_suppress on:本机回应 ARP/ND,减少 BUM 流量
#    - addrgenmode none:不自动产生 IPv6 link-local 地址
for vni in ${L2_VNIS} ${L3_VNI}; do
    ip link add vxlan${vni} type vxlan id ${vni} dstport 4789 local "${LOCAL_IP}" nolearning
    ip link add br${vni} type bridge
    ip link set br${vni} master ${VRF_NAME} addrgenmode none
    ip link set vxlan${vni} master br${vni} addrgenmode none
    ip link set vxlan${vni} type bridge_slave neigh_suppress on learning off
    ip link set up dev br${vni}
    ip link set up dev vxlan${vni}
done

# 4. 创建仿真主机并接入对应的 L2 网段
setup_host host1 h1 h1-ovs-bgp "${HOST1_CIDR}" "${GW1_CIDR%/*}" br100
setup_host host2 h2 h2-ovs-bgp "${HOST2_CIDR}" "${GW2_CIDR%/*}" br200

# 5. SVI 闸道(anycast gateway):两台配置相同 IP 与相同 MAC,主机不论接在哪台都能用同一闸道
ip link set br100 address "${GW_MAC}"
ip link set br200 address "${GW_MAC}"
ip addr add "${GW1_CIDR}" dev br100
ip addr add "${GW2_CIDR}" dev br200

echo "Server1 L3 网络配置完成。接着由 lab.sh 套用 server1-frr.conf。"

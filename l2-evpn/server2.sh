#!/usr/bin/env bash
# L2 EVPN-VXLAN 实验:Server2 的 Linux 网络配置(使用 iproute2,不使用已淘汰的 ifconfig / brctl)
# 用法:由 common/lab.sh up 在容器 evpnlab-s2 内自动运行(容器内为 root,重跑请先 lab.sh down)
# 可用环境变量覆写:LOCAL_IP、HOST_CIDR
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-10.99.0.12}"  # 容器 underlay IP(VXLAN 隧道来源)
HOST_CIDR="${HOST_CIDR:-10.0.0.2/24}"   # host1 的 IP
VNI=100

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 运行(容器内缺省为 root)" >&2
    exit 1
fi

# 1. 创建 veth pair 与 netns host1,仿真一台接在 L2 网段上的主机
ip link add h1 type veth peer name h1-ovs-bgp
ip link set h1-ovs-bgp up
ip netns add host1
ip link set h1 netns host1
ip netns exec host1 ip link set lo up
ip netns exec host1 ip link set h1 up
ip netns exec host1 ip addr add "${HOST_CIDR}" dev h1

# 2. 创建 VXLAN 接口。nolearning:关闭数据面 MAC 学习,改由 BGP EVPN(type-2)提供 MAC/IP
ip link add vxlan${VNI} type vxlan id ${VNI} dstport 4789 local "${LOCAL_IP}" nolearning

# 3. 创建 bridge 并加入 vxlan 接口(STP 缺省即为关闭)
ip link add br${VNI} type bridge stp_state 0
ip link set vxlan${VNI} master br${VNI}

# 4. 激活接口
ip link set up dev br${VNI}
ip link set up dev vxlan${VNI}

# 5. 把 host1 的 veth 接入 bridge
ip link set h1-ovs-bgp master br${VNI}

echo "Server2 L2 网络配置完成。接着由 lab.sh 套用 server2-frr.conf。"

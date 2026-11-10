#!/usr/bin/env bash
# L2 EVPN-VXLAN 實驗:Server1 的 Linux 網路設定(使用 iproute2,不使用已淘汰的 ifconfig / brctl)
# 用法:由 common/lab.sh up 在容器 evpnlab-s1 內自動執行(容器內為 root,重跑請先 lab.sh down)
# 可用環境變數覆寫:LOCAL_IP、HOST_CIDR
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-10.99.0.11}"   # 容器 underlay IP(VXLAN 隧道來源)
HOST_CIDR="${HOST_CIDR:-10.0.0.1/24}"   # host1 的 IP
VNI=100

if [ "$(id -u)" -ne 0 ]; then
    echo "請以 root 執行(容器內預設為 root)" >&2
    exit 1
fi

# 1. 建立 veth pair 與 netns host1,模擬一台接在 L2 網段上的主機
#    h1 放進 host1,另一端 h1-ovs-bgp 留在本機,稍後接上 bridge
ip link add h1 type veth peer name h1-ovs-bgp
ip link set h1-ovs-bgp up
ip netns add host1
ip link set h1 netns host1
ip netns exec host1 ip link set lo up
ip netns exec host1 ip link set h1 up
ip netns exec host1 ip addr add "${HOST_CIDR}" dev h1

# 2. 建立 VXLAN 介面。nolearning:關閉資料面 MAC 學習,改由 BGP EVPN(type-2)提供 MAC/IP
ip link add vxlan${VNI} type vxlan id ${VNI} dstport 4789 local "${LOCAL_IP}" nolearning

# 3. 建立 bridge 並加入 vxlan 介面(STP 預設即為關閉),把 VXLAN 與本機 L2 網段接在一起
ip link add br${VNI} type bridge stp_state 0
ip link set vxlan${VNI} master br${VNI}

# 4. 啟用介面
ip link set up dev br${VNI}
ip link set up dev vxlan${VNI}

# 5. 把 host1 的 veth 接入 bridge
ip link set h1-ovs-bgp master br${VNI}

echo "Server1 L2 網路設定完成。接著由 lab.sh 套用 server1-frr.conf。"

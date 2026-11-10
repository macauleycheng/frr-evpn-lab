#!/usr/bin/env bash
# 用途:在单一台主机上以 docker 创建 EVPN 实验环境(隔离 docker network + 两个 privileged FRR 容器)。
# 不使用 --network host,不修改主机 iptables / sysctl;所有配置都在容器的网络命名空间内。
# 用法:
#   ./lab.sh up l2|l3    创建环境(会先移除旧的实验资源)并套用 Linux 网络与 FRR 配置
#   ./lab.sh down        移除本脚本创建的容器与 docker network
#   ./lab.sh status      列出本实验的容器与 network
# 可用环境变量覆写:FRR_IMAGE、SUBNET、S1_IP、S2_IP
# 注意:server*-frr.conf 内写死的是缺省 IP(10.99.0.11 / 10.99.0.12),改 IP 时请同步修改。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"
PREFIX="evpnlab"                    # 本实验所有资源的名称前缀,只会操作此前缀的资源
NET_NAME="${PREFIX}-net"
SUBNET="${SUBNET:-10.99.0.0/24}"    # underlay 网段(需与主机既有 docker network 不冲突)
S1_IP="${S1_IP:-10.99.0.11}"
S2_IP="${S2_IP:-10.99.0.12}"
S1_NAME="${PREFIX}-s1"
S2_NAME="${PREFIX}-s2"
usage() {
    echo "用法:$0 up l2|l3 | down | status" >&2
    exit 1
}
# 用途:只移除本实验命名的容器与 network;不存在时不报错
lab_down() {
    local name
    for name in "${S1_NAME}" "${S2_NAME}"; do
        if docker container inspect "${name}" >/dev/null 2>&1; then
            docker rm -f "${name}" >/dev/null
            echo "已移除容器 ${name}"
        fi
    done
    if docker network inspect "${NET_NAME}" >/dev/null 2>&1; then
        docker network rm "${NET_NAME}" >/dev/null
        echo "已移除 network ${NET_NAME}"
    fi
}
# 用途:启动一台仿真 Server 的 FRR 容器
# 参数:名称 IP
start_server() {
    local name=$1 ip=$2
    # --privileged:需要创建 vxlan / bridge / vrf / netns
    # /lab:整个项目以唯读挂载,脚本与配置直接从这里运行
    docker run -d \
        --name "${name}" \
        --hostname "${name}" \
        --network "${NET_NAME}" \
        --ip "${ip}" \
        --privileged \
        -v "${SCRIPT_DIR}/daemons:/etc/frr/daemons:ro" \
        -v "${PROJECT_DIR}:/lab:ro" \
        "${FRR_IMAGE}" >/dev/null
}
# 用途:等待容器内 FRR 可用
wait_frr() {
    local name=$1 i
    for i in $(seq 1 30); do
        if docker exec "${name}" vtysh -c 'show version' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "${name} 的 FRR 未在 30 秒内启动" >&2
    return 1
}
# 用途:在容器内置立 Linux 网络并套用 FRR 配置
# 参数:名称 实验目录(l2-evpn / l3-evpn) 编号(1 / 2)
apply_lab() {
    local name=$1 dir=$2 n=$3
    docker exec "${name}" touch /etc/frr/vtysh.conf   # 避免 vtysh 找不到 vtysh.conf 的警告
    docker exec -w "/lab/${dir}" "${name}" bash "./server${n}.sh"
    docker exec "${name}" vtysh -f "/lab/${dir}/server${n}-frr.conf"
}
lab_up() {
    local dir
    case "${1:-}" in
        l2) dir=l2-evpn ;;
        l3) dir=l3-evpn ;;
        *) usage ;;
    esac
    lab_down
    docker network create --subnet "${SUBNET}" "${NET_NAME}" >/dev/null
    start_server "${S1_NAME}" "${S1_IP}"
    start_server "${S2_NAME}" "${S2_IP}"
    wait_frr "${S1_NAME}"
    wait_frr "${S2_NAME}"
    apply_lab "${S1_NAME}" "${dir}" 1
    apply_lab "${S2_NAME}" "${dir}" 2
    echo "实验 ${1} 已创建。进入 CLI:docker exec -it ${S1_NAME} vtysh"
}
case "${1:-}" in
    up) lab_up "${2:-}" ;;
    down) lab_down; echo "清理完成" ;;
    status)
        docker ps -a --filter "name=^${PREFIX}-" --format 'table {{.Names}}\t{{.Status}}'
        docker network ls --filter "name=^${NET_NAME}$"
        ;;
    *) usage ;;
esac

#!/usr/bin/env bash
# 用途:在單一台主機上以 docker 建立 EVPN 實驗環境(隔離 docker network + 兩個 privileged FRR 容器)。
# 不使用 --network host,不修改主機 iptables / sysctl;所有設定都在容器的網路命名空間內。
# 用法:
#   ./lab.sh up l2|l3    建立環境(會先移除舊的實驗資源)並套用 Linux 網路與 FRR 設定
#   ./lab.sh down        移除本腳本建立的容器與 docker network
#   ./lab.sh status      列出本實驗的容器與 network
# 可用環境變數覆寫:FRR_IMAGE、SUBNET、S1_IP、S2_IP
# 注意:server*-frr.conf 內寫死的是預設 IP(10.99.0.11 / 10.99.0.12),改 IP 時請同步修改。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
FRR_IMAGE="${FRR_IMAGE:-frrouting/frr:v8.4.1}"
PREFIX="evpnlab"                    # 本實驗所有資源的名稱前綴,只會操作此前綴的資源
NET_NAME="${PREFIX}-net"
SUBNET="${SUBNET:-10.99.0.0/24}"    # underlay 網段(需與主機既有 docker network 不衝突)
S1_IP="${S1_IP:-10.99.0.11}"
S2_IP="${S2_IP:-10.99.0.12}"
S1_NAME="${PREFIX}-s1"
S2_NAME="${PREFIX}-s2"
usage() {
    echo "用法:$0 up l2|l3 | down | status" >&2
    exit 1
}
# 用途:只移除本實驗命名的容器與 network;不存在時不報錯
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
# 用途:啟動一台模擬 Server 的 FRR 容器
# 參數:名稱 IP
start_server() {
    local name=$1 ip=$2
    # --privileged:需要建立 vxlan / bridge / vrf / netns
    # /lab:整個專案以唯讀掛載,腳本與設定直接從這裡執行
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
# 用途:等待容器內 FRR 可用
wait_frr() {
    local name=$1 i
    for i in $(seq 1 30); do
        if docker exec "${name}" vtysh -c 'show version' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "${name} 的 FRR 未在 30 秒內啟動" >&2
    return 1
}
# 用途:在容器內建立 Linux 網路並套用 FRR 設定
# 參數:名稱 實驗目錄(l2-evpn / l3-evpn) 編號(1 / 2)
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
    echo "實驗 ${1} 已建立。進入 CLI:docker exec -it ${S1_NAME} vtysh"
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

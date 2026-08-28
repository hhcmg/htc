#!/usr/bin/env bash
# VPS 出站聚合限速：HTB 负责总速率，fq 作为叶子队列配合 BBR pacing。
# 默认限制 eth0 的全部出站流量；不会修改 TCP 拥塞控制算法。

set -Eeuo pipefail

PROGRAM="vps-egress-limit"
INSTALL_PATH="/usr/local/sbin/${PROGRAM}"
CONFIG_FILE="/etc/default/${PROGRAM}"
SERVICE_FILE="/etc/systemd/system/${PROGRAM}.service"
SERVICE_NAME="${PROGRAM}.service"

DEFAULT_RATE_MBIT=300
BURST_MS=4
HTB_QUANTUM=1514

log() {
    printf '[%s] %s\n' "$PROGRAM" "$*"
}

die() {
    printf '[%s] 错误：%s\n' "$PROGRAM" "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "此操作需要 root；请先执行 sudo -i，或使用 sudo bash $0 ..."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

validate_rate() {
    local rate=$1
    [[ $rate =~ ^[1-9][0-9]*$ ]] || die "速率必须是正整数（单位 Mbps），例如 300"
    (( rate <= 100000 )) || die "速率数值异常：${rate} Mbps"
}

validate_iface() {
    local iface=$1
    [[ $iface =~ ^[[:alnum:]_.:-]+$ ]] || die "网卡名称不合法：$iface"
    [[ -d "/sys/class/net/$iface" ]] || die "网卡不存在：$iface"
}

detect_iface() {
    local iface=''

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
        if [[ -z $iface ]]; then
            iface=$(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
        fi
    fi

    [[ -n $iface ]] || die "无法自动识别公网网卡；请显式指定，例如：$0 apply 300 eth0"
    printf '%s\n' "$iface"
}

load_config() {
    IFACE=''
    RATE_MBIT=$DEFAULT_RATE_MBIT

    if [[ -r $CONFIG_FILE ]]; then
        # 配置文件由本脚本生成，内容在写入前经过严格校验。
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    IFACE=${IFACE:-$(detect_iface)}
    RATE_MBIT=${RATE_MBIT:-$DEFAULT_RATE_MBIT}
    validate_iface "$IFACE"
    validate_rate "$RATE_MBIT"
}

restore_fq() {
    local iface=$1
    require_command tc
    validate_iface "$iface"
    tc qdisc replace dev "$iface" root fq
    log "已关闭 HTB，${iface} 已恢复为根队列 fq。"
}

apply_limit() {
    local rate=$1
    local iface=$2
    local burst_bytes

    require_command tc
    validate_rate "$rate"
    validate_iface "$iface"

    # rate(Mbit/s) × 1,000,000 / 8 × BURST_MS/1000
    # BURST_MS=4 时可简化为 rate × 500 字节。
    burst_bytes=$((rate * 1000000 / 8 * BURST_MS / 1000))
    (( burst_bytes >= HTB_QUANTUM )) || burst_bytes=$HTB_QUANTUM

    # 尽力加载内核模块；若已内建或已加载，modprobe 失败不影响 tc 尝试。
    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_htb 2>/dev/null || true
        modprobe sch_fq 2>/dev/null || true
    fi

    tc qdisc replace dev "$iface" root handle 1: htb default 10

    if ! tc class replace dev "$iface" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" \
        burst "$burst_bytes" cburst "$burst_bytes" \
        quantum "$HTB_QUANTUM"; then
        tc qdisc replace dev "$iface" root fq || true
        die "创建 HTB 类失败；已尝试恢复根队列 fq"
    fi

    if ! tc qdisc replace dev "$iface" parent 1:10 handle 10: fq; then
        tc qdisc replace dev "$iface" root fq || true
        die "创建子队列 fq 失败；已尝试恢复根队列 fq"
    fi

    log "已生效：${iface} 全部出站流量聚合限制为 ${rate} Mbps。"
    log "结构：HTB 1: → class 1:10 → fq 10:；burst/cburst=${burst_bytes} 字节。"
}

show_status() {
    local iface=$1
    validate_iface "$iface"
    require_command tc

    printf '\n--- TCP 拥塞控制 ---\n'
    if command -v sysctl >/dev/null 2>&1; then
        sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
    fi

    printf '\n--- %s 队列规则 ---\n' "$iface"
    tc -s -d qdisc show dev "$iface"

    printf '\n--- %s HTB 类 ---\n' "$iface"
    tc -s -d class show dev "$iface"

    if command -v systemctl >/dev/null 2>&1 && [[ -f $SERVICE_FILE ]]; then
        printf '\n--- 永久服务 ---\n'
        systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true
        systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
    fi
}

write_config() {
    local rate=$1
    local iface=$2
    local tmp

    validate_rate "$rate"
    validate_iface "$iface"
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    printf 'IFACE=%s\nRATE_MBIT=%s\n' "$iface" "$rate" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

install_permanent() {
    local rate=$1
    local iface=$2
    local source_path

    require_root
    require_command tc
    require_command systemctl
    require_command install
    validate_rate "$rate"
    validate_iface "$iface"

    source_path=$(readlink -f "${BASH_SOURCE[0]}")
    [[ -f $source_path ]] || die "无法定位当前脚本；请先将脚本保存为本地文件，再执行 install"

    if [[ $source_path != "$INSTALL_PATH" ]]; then
        install -m 0755 "$source_path" "$INSTALL_PATH"
    else
        chmod 0755 "$INSTALL_PATH"
    fi

    write_config "$rate" "$iface"

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=VPS aggregate egress rate limit using HTB and fq
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH service-start
ExecReload=$INSTALL_PATH service-start
ExecStop=$INSTALL_PATH service-stop

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"

    log "永久限速已安装并启动：${iface} = ${rate} Mbps。"
    log "永久参数：$CONFIG_FILE"
    log "systemd 服务：$SERVICE_FILE"
}

set_permanent_rate() {
    local rate=$1

    require_root
    [[ -f $SERVICE_FILE && -x $INSTALL_PATH ]] || die "尚未安装永久服务；请先执行：$0 install $rate"
    load_config
    write_config "$rate" "$IFACE"
    systemctl restart "$SERVICE_NAME"
    log "永久速率已更新并立即生效：${IFACE} = ${rate} Mbps。"
}

disable_permanent() {
    require_root
    require_command systemctl
    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE_NAME"
    else
        load_config
        restore_fq "$IFACE"
    fi
    log "已停止限速并取消开机启动；脚本和配置文件仍保留。"
}

enable_permanent() {
    require_root
    require_command systemctl
    [[ -f $SERVICE_FILE && -x $INSTALL_PATH && -f $CONFIG_FILE ]] || die "永久服务文件不完整；请重新执行 install"
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"
    log "已启用永久限速并恢复开机启动。"
}

uninstall_permanent() {
    local iface

    require_root
    require_command systemctl
    if [[ -r $CONFIG_FILE ]]; then
        load_config
        iface=$IFACE
    else
        iface=$(detect_iface)
    fi

    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    fi
    restore_fq "$iface"

    rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$INSTALL_PATH"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    log "永久服务、配置和安装副本已删除；当前脚本原文件未删除。"
}

usage() {
    cat <<EOF
用法：
  $0 apply [Mbps] [网卡]    临时开启限速；默认 ${DEFAULT_RATE_MBIT} Mbps，自动识别网卡
  $0 off [网卡]             临时关闭 HTB，恢复根队列 fq
  $0 status [网卡]          查看 BBR、qdisc、class 和永久服务状态

  $0 install [Mbps] [网卡]  安装为永久服务并立即开启
  $0 set-rate <Mbps>         修改永久速率并立即重启服务
  $0 disable                 停止限速并取消开机启动，保留文件
  $0 enable                  重新启用永久限速和开机启动
  $0 uninstall               彻底删除永久配置并恢复根队列 fq

推荐流程：
  $0 apply 300 eth0
  $0 status eth0
  $0 off eth0
  $0 install 300 eth0

说明：
  1. 限制的是指定网卡的全部出站流量总和，不是每个连接各 ${DEFAULT_RATE_MBIT} Mbps。
  2. 脚本不修改 BBR；启用时使用“HTB 根队列 + fq 子队列”，关闭时恢复“fq 根队列”。
  3. apply/off 是临时操作；install 后参数保存在 $CONFIG_FILE。
EOF
}

main() {
    local command=${1:-help}
    local rate iface

    case "$command" in
        apply)
            require_root
            rate=${2:-$DEFAULT_RATE_MBIT}
            iface=${3:-$(detect_iface)}
            apply_limit "$rate" "$iface"
            ;;
        off)
            require_root
            iface=${2:-$(detect_iface)}
            restore_fq "$iface"
            ;;
        status)
            iface=${2:-$(detect_iface)}
            show_status "$iface"
            ;;
        install)
            rate=${2:-$DEFAULT_RATE_MBIT}
            iface=${3:-$(detect_iface)}
            install_permanent "$rate" "$iface"
            ;;
        set-rate)
            [[ $# -ge 2 ]] || die "请提供新速率，例如：$0 set-rate 300"
            validate_rate "$2"
            set_permanent_rate "$2"
            ;;
        disable)
            disable_permanent
            ;;
        enable)
            enable_permanent
            ;;
        uninstall)
            uninstall_permanent
            ;;
        service-start)
            require_root
            load_config
            apply_limit "$RATE_MBIT" "$IFACE"
            ;;
        service-stop)
            require_root
            load_config
            restore_fq "$IFACE"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            die "未知操作：$command"
            ;;
    esac
}

main "$@"

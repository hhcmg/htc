#!/usr/bin/env bash
# VPS 双向聚合限速：物理网卡出站使用 HTB + fq，入站通过 IFB 重定向后整形。
# 两个方向可独立开启或关闭；不会修改 TCP 拥塞控制算法。

set -Eeuo pipefail

PROGRAM="vps-egress-limit"
INSTALL_PATH="/usr/local/sbin/${PROGRAM}"
CONFIG_FILE="/etc/default/${PROGRAM}"
SERVICE_FILE="/etc/systemd/system/${PROGRAM}.service"
SERVICE_NAME="${PROGRAM}.service"

DEFAULT_EGRESS_RATE_MBIT=300
DEFAULT_INGRESS_RATE_MBIT=off
DEFAULT_IFB_IFACE="ifb-vpslimit"
INGRESS_FILTER_PREF=49152
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

normalize_rate_setting() {
    local value=${1,,}

    case "$value" in
        off|none|unlimited|0)
            printf 'off\n'
            ;;
        *)
            validate_rate "$value"
            printf '%s\n' "$value"
            ;;
    esac
}

is_rate_setting() {
    local value=${1,,}
    [[ $value =~ ^[1-9][0-9]*$ || $value == off || $value == none || $value == unlimited || $value == 0 ]]
}

validate_iface_name() {
    local iface=$1
    [[ $iface =~ ^[-[:alnum:]_.:]+$ ]] || die "网卡名称不合法：$iface"
    (( ${#iface} <= 15 )) || die "网卡名称过长：$iface（Linux 最多 15 个字符）"
}

validate_iface() {
    local iface=$1
    validate_iface_name "$iface"
    [[ -d "/sys/class/net/$iface" ]] || die "网卡不存在：$iface"
}

detect_iface() {
    local iface=''

    require_command ip
    require_command awk
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    if [[ -z $iface ]]; then
        iface=$(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    fi

    [[ -n $iface ]] || die "无法自动识别公网网卡；请显式指定，例如：$0 apply 300 off eth0"
    printf '%s\n' "$iface"
}

load_config() {
    IFACE=''
    IFB_IFACE=''
    EGRESS_RATE_MBIT=''
    INGRESS_RATE_MBIT=''
    RATE_MBIT=''

    if [[ -r $CONFIG_FILE ]]; then
        # 配置文件由本脚本生成，内容在写入前经过严格校验。
        # RATE_MBIT 用于兼容旧版本生成的配置。
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    IFACE=${IFACE:-$(detect_iface)}
    IFB_IFACE=${IFB_IFACE:-$DEFAULT_IFB_IFACE}
    EGRESS_RATE_MBIT=${EGRESS_RATE_MBIT:-${RATE_MBIT:-$DEFAULT_EGRESS_RATE_MBIT}}
    INGRESS_RATE_MBIT=${INGRESS_RATE_MBIT:-$DEFAULT_INGRESS_RATE_MBIT}

    validate_iface "$IFACE"
    validate_iface_name "$IFB_IFACE"
    EGRESS_RATE_MBIT=$(normalize_rate_setting "$EGRESS_RATE_MBIT")
    INGRESS_RATE_MBIT=$(normalize_rate_setting "$INGRESS_RATE_MBIT")
}

load_qdisc_modules() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_htb 2>/dev/null || true
        modprobe sch_fq 2>/dev/null || true
    fi
}

calculate_burst_bytes() {
    local rate=$1
    local burst_bytes

    # rate(Mbit/s) × 1,000,000 / 8 × BURST_MS/1000
    # BURST_MS=4 时可简化为 rate × 500 字节。
    burst_bytes=$((rate * 1000000 / 8 * BURST_MS / 1000))
    (( burst_bytes >= HTB_QUANTUM )) || burst_bytes=$HTB_QUANTUM
    printf '%s\n' "$burst_bytes"
}

configure_htb() {
    local rate=$1
    local device=$2
    local burst_bytes

    burst_bytes=$(calculate_burst_bytes "$rate")
    tc qdisc replace dev "$device" root handle 1: htb default 10 || return 1
    tc class replace dev "$device" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" \
        burst "$burst_bytes" cburst "$burst_bytes" \
        quantum "$HTB_QUANTUM" || return 1
    tc qdisc replace dev "$device" parent 1:10 handle 10: fq || return 1
}

restore_fq() {
    local iface=$1
    require_command tc
    validate_iface "$iface"
    load_qdisc_modules
    tc qdisc replace dev "$iface" root fq
    log "${iface} 的出站 HTB 已关闭，根队列已恢复为 fq。"
}

apply_egress_limit() {
    local rate=$1
    local iface=$2
    local burst_bytes

    require_command tc
    validate_rate "$rate"
    validate_iface "$iface"
    load_qdisc_modules

    if ! configure_htb "$rate" "$iface"; then
        tc qdisc replace dev "$iface" root fq 2>/dev/null || true
        die "创建 ${iface} 的出站 HTB/fq 失败；已尝试恢复根队列 fq"
    fi

    burst_bytes=$(calculate_burst_bytes "$rate")
    log "已生效：${iface} 全部出站流量聚合限制为 ${rate} Mbps。"
    log "出站结构：${iface} HTB 1: → class 1:10 → fq 10:；burst/cburst=${burst_bytes} 字节。"
}

ifb_alias() {
    local ifb=$1
    local alias=''

    if [[ -r "/sys/class/net/$ifb/ifalias" ]]; then
        IFS= read -r alias <"/sys/class/net/$ifb/ifalias" || true
    fi
    printf '%s\n' "$alias"
}

ensure_ifb() {
    local ifb=$1
    local alias
    local created=0

    require_command ip
    validate_iface_name "$ifb"

    if command -v modprobe >/dev/null 2>&1; then
        modprobe ifb 2>/dev/null || true
        modprobe act_mirred 2>/dev/null || true
        modprobe cls_u32 2>/dev/null || true
    fi

    if [[ ! -d "/sys/class/net/$ifb" ]]; then
        ip link add name "$ifb" type ifb || die "无法创建 IFB 网卡：$ifb"
        created=1
        if ! ip link set dev "$ifb" alias "$PROGRAM"; then
            ip link delete dev "$ifb" type ifb 2>/dev/null || true
            die "无法标记 IFB 网卡所有权：$ifb"
        fi
    fi

    alias=$(ifb_alias "$ifb")
    if [[ $alias != "$PROGRAM" ]]; then
        (( created == 0 )) || ip link delete dev "$ifb" type ifb 2>/dev/null || true
        die "IFB 名称 ${ifb} 已被其他配置占用；请移除冲突或修改 $CONFIG_FILE 中的 IFB_IFACE"
    fi

    ip link set dev "$ifb" up || die "无法启用 IFB 网卡：$ifb"
}

remove_ingress_filter() {
    local iface=$1
    tc filter del dev "$iface" parent ffff: pref "$INGRESS_FILTER_PREF" 2>/dev/null || true
}

remove_owned_ifb() {
    local ifb=$1

    if [[ -d "/sys/class/net/$ifb" && $(ifb_alias "$ifb") == "$PROGRAM" ]]; then
        tc qdisc del dev "$ifb" root 2>/dev/null || true
        ip link set dev "$ifb" down 2>/dev/null || true
        ip link delete dev "$ifb" type ifb 2>/dev/null || true
    fi
}

disable_ingress_limit() {
    local iface=$1
    local ifb=$2

    require_command tc
    require_command ip
    validate_iface "$iface"
    validate_iface_name "$ifb"
    remove_ingress_filter "$iface"
    remove_owned_ifb "$ifb"
    log "${iface} 的入站重定向和 IFB 限速已关闭。"
}

apply_ingress_limit() {
    local rate=$1
    local iface=$2
    local ifb=$3
    local burst_bytes

    require_command tc
    require_command ip
    validate_rate "$rate"
    validate_iface "$iface"
    validate_iface_name "$ifb"
    [[ $iface != "$ifb" ]] || die "物理网卡和 IFB 网卡不能同名：$iface"
    load_qdisc_modules
    ensure_ifb "$ifb"

    if ! configure_htb "$rate" "$ifb"; then
        remove_owned_ifb "$ifb"
        die "创建 ${ifb} 的入站 HTB/fq 失败；已清理脚本创建的 IFB 网卡"
    fi

    # 如果接口已有 ingress 或 clsact，add 会失败，但后续添加过滤器仍可正常工作。
    tc qdisc add dev "$iface" handle ffff: ingress 2>/dev/null || true
    remove_ingress_filter "$iface"
    if ! tc filter add dev "$iface" parent ffff: protocol all pref "$INGRESS_FILTER_PREF" \
        u32 match u32 0 0 action mirred egress redirect dev "$ifb"; then
        remove_ingress_filter "$iface"
        remove_owned_ifb "$ifb"
        die "无法把 ${iface} 的入站流量重定向到 ${ifb}；已清理本次 IFB 配置"
    fi

    burst_bytes=$(calculate_burst_bytes "$rate")
    log "已生效：${iface} 全部入站流量聚合限制为 ${rate} Mbps。"
    log "入站结构：${iface} ingress → ${ifb} → HTB 1: → class 1:10 → fq 10:；burst/cburst=${burst_bytes} 字节。"
}

apply_limits() {
    local egress=$1
    local ingress=$2
    local iface=$3
    local ifb=$4

    if [[ $egress == off ]]; then
        restore_fq "$iface"
    else
        apply_egress_limit "$egress" "$iface"
    fi

    if [[ $ingress == off ]]; then
        disable_ingress_limit "$iface" "$ifb"
    else
        apply_ingress_limit "$ingress" "$iface" "$ifb"
    fi
}

show_status() {
    local iface=$1
    local ifb=${2:-$DEFAULT_IFB_IFACE}

    validate_iface "$iface"
    validate_iface_name "$ifb"
    require_command tc

    printf '\n--- TCP 拥塞控制 ---\n'
    if command -v sysctl >/dev/null 2>&1; then
        sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
    fi

    if [[ -r $CONFIG_FILE ]]; then
        load_config
        ifb=$IFB_IFACE
        printf '\n--- 永久配置 ---\n'
        printf '网卡：%s\n出站限制：%s\n入站限制：%s\nIFB：%s\n' \
            "$IFACE" "$EGRESS_RATE_MBIT" "$INGRESS_RATE_MBIT" "$IFB_IFACE"
    fi

    printf '\n--- %s 出站队列规则 ---\n' "$iface"
    tc -s -d qdisc show dev "$iface"

    printf '\n--- %s 出站 HTB 类 ---\n' "$iface"
    tc -s -d class show dev "$iface"

    printf '\n--- %s 入站重定向过滤器 ---\n' "$iface"
    tc -s -d filter show dev "$iface" parent ffff: 2>/dev/null || printf '未配置入站重定向。\n'

    printf '\n--- %s 入站整形队列 ---\n' "$ifb"
    if [[ -d "/sys/class/net/$ifb" ]]; then
        tc -s -d qdisc show dev "$ifb"
        tc -s -d class show dev "$ifb"
    else
        printf 'IFB 网卡不存在，入站限速未启用。\n'
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -f $SERVICE_FILE ]]; then
        printf '\n--- 永久服务 ---\n'
        systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true
        systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
    fi
}

write_config() {
    local egress=$1
    local ingress=$2
    local iface=$3
    local ifb=$4
    local tmp

    egress=$(normalize_rate_setting "$egress")
    ingress=$(normalize_rate_setting "$ingress")
    validate_iface "$iface"
    validate_iface_name "$ifb"
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    printf 'IFACE=%s\nIFB_IFACE=%s\nEGRESS_RATE_MBIT=%s\nINGRESS_RATE_MBIT=%s\n' \
        "$iface" "$ifb" "$egress" "$ingress" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

install_permanent() {
    local egress=$1
    local ingress=$2
    local iface=$3
    local ifb=$4
    local source_path

    require_root
    require_command tc
    require_command ip
    require_command systemctl
    require_command install
    egress=$(normalize_rate_setting "$egress")
    ingress=$(normalize_rate_setting "$ingress")
    validate_iface "$iface"
    validate_iface_name "$ifb"
    [[ $egress != off || $ingress != off ]] || die "出站和入站不能同时设为 off；无需安装一个不执行限速的服务"

    source_path=$(readlink -f "${BASH_SOURCE[0]}")
    [[ -f $source_path ]] || die "无法定位当前脚本；请先将脚本保存为本地文件，再执行 install"

    if [[ $source_path != "$INSTALL_PATH" ]]; then
        install -m 0755 "$source_path" "$INSTALL_PATH"
    else
        chmod 0755 "$INSTALL_PATH"
    fi

    write_config "$egress" "$ingress" "$iface" "$ifb"

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=VPS aggregate ingress and egress rate limits using HTB, fq and IFB
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

    log "永久限速已安装并启动：${iface}，出站=${egress} Mbps，入站=${ingress} Mbps。"
    log "永久参数：$CONFIG_FILE"
    log "systemd 服务：$SERVICE_FILE"
}

set_permanent_rates() {
    local egress_arg=$1
    local ingress_arg=${2:-keep}
    local new_egress
    local new_ingress

    require_root
    require_command systemctl
    [[ -f $SERVICE_FILE && -x $INSTALL_PATH ]] || die "尚未安装永久服务；请先执行 install"
    load_config
    new_egress=$EGRESS_RATE_MBIT
    new_ingress=$INGRESS_RATE_MBIT

    if [[ ${egress_arg,,} != keep ]]; then
        new_egress=$(normalize_rate_setting "$egress_arg")
    fi
    if [[ ${ingress_arg,,} != keep ]]; then
        new_ingress=$(normalize_rate_setting "$ingress_arg")
    fi
    [[ $new_egress != off || $new_ingress != off ]] || die "出站和入站不能同时设为 off；请使用 disable 停止永久服务"

    write_config "$new_egress" "$new_ingress" "$IFACE" "$IFB_IFACE"
    systemctl restart "$SERVICE_NAME"
    log "永久速率已更新并立即生效：${IFACE}，出站=${new_egress} Mbps，入站=${new_ingress} Mbps。"
}

disable_all_limits() {
    local iface=$1
    local ifb=$2
    restore_fq "$iface"
    disable_ingress_limit "$iface" "$ifb"
}

disable_permanent() {
    require_root
    require_command systemctl
    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE_NAME"
    else
        load_config
        disable_all_limits "$IFACE" "$IFB_IFACE"
    fi
    log "已停止双向限速并取消开机启动；脚本和配置文件仍保留。"
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
    local ifb

    require_root
    require_command systemctl
    if [[ -r $CONFIG_FILE ]]; then
        load_config
        iface=$IFACE
        ifb=$IFB_IFACE
    else
        iface=$(detect_iface)
        ifb=$DEFAULT_IFB_IFACE
    fi

    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    fi
    disable_all_limits "$iface" "$ifb"

    rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$INSTALL_PATH"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    log "永久服务、配置和安装副本已删除；当前脚本原文件未删除。"
}

parse_limit_args() {
    local default_egress=$1
    local default_ingress=$2
    shift 2

    PARSED_EGRESS=$default_egress
    PARSED_INGRESS=$default_ingress
    PARSED_IFACE=''

    case $# in
        0) ;;
        1)
            PARSED_EGRESS=$1
            ;;
        2)
            PARSED_EGRESS=$1
            if is_rate_setting "$2"; then
                PARSED_INGRESS=$2
            else
                # 兼容旧语法：apply/install <出站Mbps> <网卡>
                PARSED_IFACE=$2
            fi
            ;;
        3)
            PARSED_EGRESS=$1
            PARSED_INGRESS=$2
            PARSED_IFACE=$3
            ;;
        *)
            die "参数过多"
            ;;
    esac

    PARSED_EGRESS=$(normalize_rate_setting "$PARSED_EGRESS")
    PARSED_INGRESS=$(normalize_rate_setting "$PARSED_INGRESS")
    PARSED_IFACE=${PARSED_IFACE:-$(detect_iface)}
    validate_iface "$PARSED_IFACE"
}

usage() {
    cat <<EOF
用法：
  $0 apply [出站Mbps|off] [入站Mbps|off] [网卡]
      临时应用双向限速；默认出站 ${DEFAULT_EGRESS_RATE_MBIT} Mbps、入站 off，并自动识别网卡
      兼容旧语法：$0 apply [出站Mbps] [网卡]

  $0 off [all|egress|ingress] [网卡]
      临时关闭全部、仅出站或仅入站限速；默认 all

  $0 status [网卡]
      查看拥塞控制、物理网卡出站队列、入站 IFB 和永久服务状态

  $0 install [出站Mbps|off] [入站Mbps|off] [网卡]
      安装为永久服务并立即应用；兼容旧语法：install [出站Mbps] [网卡]

  $0 set-rate <出站Mbps|off|keep> [入站Mbps|off|keep]
      修改永久速率并立即重启服务；省略第二项时保持当前入站设置

  $0 disable                 停止全部限速并取消开机启动，保留文件
  $0 enable                  重新启用永久限速和开机启动
  $0 uninstall               删除永久配置并关闭双向限速

示例：
  $0 apply 300 400 eth0       出站 300 Mbps，入站 400 Mbps
  $0 apply off 400 eth0       出站不限，入站 400 Mbps
  $0 apply 300 off eth0       出站 300 Mbps，入站不限（兼容旧行为）
  $0 off ingress eth0         只关闭入站限速
  $0 install 300 400 eth0     永久配置双向限速
  $0 set-rate keep 500        仅将永久入站限制改为 500 Mbps
  $0 set-rate off 400         永久出站不限、入站 400 Mbps

说明：
  1. 方向始终以服务器为参照：服务器发送是出站，服务器接收是入站。
  2. 出站使用物理网卡 HTB + fq；入站使用 ingress 重定向 + IFB + HTB + fq。
  3. off、none、unlimited 和 0 都表示该方向不限速；配置中统一保存为 off。
  4. 脚本不修改 BBR 或其他 TCP 拥塞控制设置。
  5. apply/off 是临时操作；install 后参数保存在 $CONFIG_FILE。
EOF
}

main() {
    local command=${1:-help}
    local direction iface

    case "$command" in
        apply)
            require_root
            shift
            parse_limit_args "$DEFAULT_EGRESS_RATE_MBIT" "$DEFAULT_INGRESS_RATE_MBIT" "$@"
            apply_limits "$PARSED_EGRESS" "$PARSED_INGRESS" "$PARSED_IFACE" "$DEFAULT_IFB_IFACE"
            ;;
        off)
            require_root
            direction=${2:-all}
            case "${direction,,}" in
                all|egress|ingress)
                    iface=${3:-$(detect_iface)}
                    ;;
                *)
                    # 兼容旧语法：off <网卡>
                    iface=$direction
                    direction=all
                    ;;
            esac
            validate_iface "$iface"
            case "${direction,,}" in
                all) disable_all_limits "$iface" "$DEFAULT_IFB_IFACE" ;;
                egress) restore_fq "$iface" ;;
                ingress) disable_ingress_limit "$iface" "$DEFAULT_IFB_IFACE" ;;
            esac
            ;;
        status)
            iface=${2:-$(detect_iface)}
            show_status "$iface" "$DEFAULT_IFB_IFACE"
            ;;
        install)
            shift
            parse_limit_args "$DEFAULT_EGRESS_RATE_MBIT" "$DEFAULT_INGRESS_RATE_MBIT" "$@"
            install_permanent "$PARSED_EGRESS" "$PARSED_INGRESS" "$PARSED_IFACE" "$DEFAULT_IFB_IFACE"
            ;;
        set-rate)
            [[ $# -ge 2 && $# -le 3 ]] || die "用法：$0 set-rate <出站Mbps|off|keep> [入站Mbps|off|keep]"
            set_permanent_rates "$2" "${3:-keep}"
            ;;
        disable) disable_permanent ;;
        enable) enable_permanent ;;
        uninstall) uninstall_permanent ;;
        service-start)
            require_root
            load_config
            apply_limits "$EGRESS_RATE_MBIT" "$INGRESS_RATE_MBIT" "$IFACE" "$IFB_IFACE"
            ;;
        service-stop)
            require_root
            load_config
            disable_all_limits "$IFACE" "$IFB_IFACE"
            ;;
        help|-h|--help) usage ;;
        *)
            usage >&2
            die "未知操作：$command"
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

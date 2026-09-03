#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=../vps-egress-limit.sh
source "$REPO_DIR/vps-egress-limit.sh"

# 参数解析测试不访问真实 Linux 网卡。
detect_iface() {
    printf 'eth0\n'
}

validate_iface() {
    :
}

assert_parse() {
    local expected_egress=$1
    local expected_ingress=$2
    local expected_iface=$3
    shift 3

    parse_limit_args "$DEFAULT_EGRESS_RATE_MBIT" "$DEFAULT_INGRESS_RATE_MBIT" "$@"
    [[ $PARSED_EGRESS == "$expected_egress" ]] || return 1
    [[ $PARSED_INGRESS == "$expected_ingress" ]] || return 1
    [[ $PARSED_IFACE == "$expected_iface" ]] || return 1
}

assert_parse 300 off eth0
assert_parse 300 off eth0 300
assert_parse 300 off eth0 300 eth0
assert_parse 300 400 eth0 300 400
assert_parse 300 400 eth0 300 400 eth0
assert_parse off 400 eth0 off 400 eth0
assert_parse 300 off eth0 300 off eth0

[[ $(normalize_rate_setting 0) == off ]]
[[ $(normalize_rate_setting unlimited) == off ]]
[[ $(normalize_rate_setting 500) == 500 ]]

printf 'CLI parsing tests passed.\n'

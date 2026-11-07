#!/bin/bash
# 新客户接入：向维护 VPS 签发一次性短码，生成客户机命令并复制到剪贴板。
# MVP：只做 Windows 客户机；macOS 客户机入口下一轮补上。
set -Eeo pipefail
export LC_ALL=en_US.UTF-8

CONFIG_DIR="$HOME/.wgmaint"
DEFAULT_MSI="$HOME/.win-clients/pkg/wireguard-amd64-1.1.1.msi"
DEFAULT_KEY="$HOME/.ssh/id_ed25519.pub"

VPS_TARGET=""
COPY=0
PLATFORM="windows"
KEY="$DEFAULT_KEY"
MSI="$DEFAULT_MSI"
FORCE_REGISTER=0
SKIP_WG=0
REPORTS=0

usage() {
    cat <<'TEXT'
用法：new-customer.sh --vps admin@VPS [--copy] [--platform windows|mac]
                      [--register] [--key 公钥文件] [--msi 安装包]
TEXT
}

notify() {
    osascript -e "display notification \"$1\" with title \"新客户接入\"" >/dev/null 2>&1 || true
}

alert() {
    local text=$1
    local detail=$2
    osascript -e "display alert \"$text\" message \"$detail\" as critical" >/dev/null 2>&1 || true
}

die() {
    printf '无法生成接入命令：%s\n' "$*" >&2
    [ "$COPY" -eq 1 ] && alert "新客户接入失败" "$*"
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --vps)
            VPS_TARGET=$2
            shift 2
            ;;
        --copy)
            COPY=1
            shift
            ;;
        --platform)
            PLATFORM=$2
            shift 2
            ;;
        --key)
            KEY=$2
            shift 2
            ;;
        --msi)
            MSI=$2
            shift 2
            ;;
        --register)
            FORCE_REGISTER=1
            shift
            ;;
        --skip-wg)
            SKIP_WG=1
            shift
            ;;
        --reports)
            REPORTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
done

[ "$PLATFORM" = "windows" ] || die "macOS 客户机接入尚未启用（MVP 先做 Windows）。"
if [ -z "$VPS_TARGET" ]; then
    VPS_TARGET=$WGMAINT_VPS
fi
[ -n "$VPS_TARGET" ] || die "请用 --vps 指定维护 VPS，例如 admin@1.2.3.4。"

if [ "$REPORTS" -eq 0 ]; then
    [ -f "$KEY" ] || die "找不到 SSH 公钥：$KEY"
    [ -f "$MSI" ] || die "找不到 WireGuard 安装包：$MSI"
fi

vps_id=$(printf '%s' "$VPS_TARGET" | shasum -a 256 | cut -c1-8)
dir="$CONFIG_DIR/$vps_id"
config="$dir/config.env"
iface="wgm-$vps_id"
admin_conf="$dir/$iface.conf"

CFG_JOIN=""
CFG_ENDPOINT=""
CFG_NETWORK=""
CFG_SERVER_PUB=""
CFG_ADMIN_IP=""
CFG_ADMIN_KEY=""
CFG_ADMIN_TOKEN=""

read_field() {
    printf '%s' "$1" | cut -d= -f2-
}

parse_config_line() {
    local key value
    key=$(printf '%s' "$1" | cut -d= -f1)
    value=$(read_field "$1")
    case $key in
        join) CFG_JOIN=$value ;;
        endpoint) CFG_ENDPOINT=$value ;;
        network) CFG_NETWORK=$value ;;
        server_public_key) CFG_SERVER_PUB=$value ;;
        admin_ip) CFG_ADMIN_IP=$value ;;
        admin_private_key) CFG_ADMIN_KEY=$value ;;
        admin_token) CFG_ADMIN_TOKEN=$value ;;
    esac
}

load_config() {
    local line
    [ -f "$config" ] || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        parse_config_line "$line"
    done <"$config"
    [ -n "$CFG_JOIN" ] || return 1
    printf '%s' "$CFG_ADMIN_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || return 1
    printf '%s' "$CFG_SERVER_PUB" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || return 1
    printf '%s' "$CFG_ADMIN_TOKEN" | grep -Eq '^[A-Za-z0-9_-]{43}$' || return 1
    return 0
}

save_config() {
    mkdir -p "$dir"
    chmod 700 "$CONFIG_DIR" "$dir"
    umask 077
    cat >"$config" <<EOF
join=$CFG_JOIN
endpoint=$CFG_ENDPOINT
network=$CFG_NETWORK
server_public_key=$CFG_SERVER_PUB
admin_ip=$CFG_ADMIN_IP
admin_private_key=$CFG_ADMIN_KEY
admin_token=$CFG_ADMIN_TOKEN
EOF
    chmod 600 "$config"
}

write_admin_conf() {
    mkdir -p "$dir"
    chmod 700 "$CONFIG_DIR" "$dir"
    umask 077
    cat >"$admin_conf" <<EOF
[Interface]
PrivateKey = $CFG_ADMIN_KEY
Address = $CFG_ADMIN_IP/32

[Peer]
PublicKey = $CFG_SERVER_PUB
Endpoint = $CFG_ENDPOINT
AllowedIPs = $CFG_NETWORK
PersistentKeepalive = 25
EOF
    chmod 600 "$admin_conf"
}

apply_registration() {
    local encoded payload line
    encoded=$(printf '%s' "$1" | cut -c5-)
    if ! payload=$(printf '%s' "$encoded" | base64 -D 2>/dev/null); then
        payload=$(printf '%s' "$encoded" | base64 -d)
    fi
    [ -n "$payload" ] || die "登记码解码失败。"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        parse_config_line "$line"
    done <<<"$payload"
    [ -n "$CFG_JOIN" ] && [ -n "$CFG_ADMIN_TOKEN" ] && [ -n "$CFG_ADMIN_KEY" ] ||
        die "登记码内容不完整。"
    printf '%s' "$CFG_ADMIN_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || die "登记码里的隧道私钥无效。"
    printf '%s' "$CFG_SERVER_PUB" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || die "登记码里的服务器公钥无效。"
    case $CFG_JOIN in
        http://*) ;;
        *) die "登记码里的接入地址无效。" ;;
    esac
    write_admin_conf
    save_config
}

ask_register() {
    local answer
    answer=$(osascript <<'APPLESCRIPT' 2>/dev/null || true
text returned of (display dialog "第一次在这台 Mac 上使用这台维护 VPS。请粘贴 VPS 部署结束时输出的登记码（WM2: 开头）：" default answer "" buttons {"取消", "确定"} default button "确定")
APPLESCRIPT
)
    printf '%s' "$answer"
}

normalize_registration() {
    case $1 in
        WM2:*) printf '%s' "$1" ;;
        version=2*) printf 'WM2:%s' "$(printf '%s
' "$1" | base64 | tr -d '
')" ;;
        *) printf '' ;;
    esac
}

obtain_registration() {
    local output
    REGISTER=""
    if [ -n "$WGMAINT_REGISTER" ]; then
        REGISTER=$(normalize_registration "$WGMAINT_REGISTER")
    elif [ "$FORCE_REGISTER" -eq 0 ]; then
        output=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$VPS_TARGET" </dev/null 2>/dev/null || true)
        REGISTER=$(normalize_registration "$output")
        if [ -z "$REGISTER" ]; then
            output=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$VPS_TARGET" 'sudo -n /usr/local/bin/wgmaint invite' </dev/null 2>/dev/null || true)
            REGISTER=$(normalize_registration "$output")
        fi
    fi
    if [ -z "$REGISTER" ]; then
        REGISTER=$(normalize_registration "$(ask_register)")
    fi
    [ -n "$REGISTER" ] || die "没有拿到登记码，请在 VPS 上重新部署后粘贴 WM2 登记码。"
    case $REGISTER in
        WM2:*) ;;
        *) die "登记码格式不对，应以 WM2: 开头。" ;;
    esac
}

ensure_tunnel() {
    local wg_quick runner log tail_text
    [ "$SKIP_WG" -eq 1 ] && return 0
    wg_quick=$(command -v wg-quick || true)
    [ -n "$wg_quick" ] || die "没有找到 wg-quick，请先安装 wireguard-tools。"
    runner="$dir/up.sh"
    log="$dir/wg.log"
    cat >"$runner" <<EOF
#!/bin/bash
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if wg show '$iface' >/dev/null 2>&1; then chmod 0644 '$log' 2>/dev/null; exit 0; fi
'$wg_quick' up '$admin_conf' >>'$log' 2>&1 && { chmod 0644 '$log' 2>/dev/null; exit 0; }
'$wg_quick' down '$admin_conf' >>'$log' 2>&1 || true
'$wg_quick' up '$admin_conf' >>'$log' 2>&1
chmod 0644 '$log' 2>/dev/null || true
EOF
    chmod 700 "$runner"
    if sudo -n true >/dev/null 2>&1; then
        if sudo -n /bin/bash "$runner"; then
            return 0
        fi
        tail_text=$(sudo -n cat "$log" 2>/dev/null | tail -6 | tr '
' ' ' || true)
    elif osascript -e "do shell script "/bin/bash '$runner'" with administrator privileges" >/dev/null 2>&1; then
        return 0
    else
        tail_text=$(tail -6 "$log" 2>/dev/null | tr '
' ' ' || true)
    fi
    [ -n "$tail_text" ] || tail_text="请查看 $log"
    die "启动维护隧道失败：$tail_text"
}

ensure_package() {
    local status remote_sha local_sha response
    status=$(curl -fsS --max-time 10 -H "Authorization: Bearer $CFG_ADMIN_TOKEN" "$CFG_JOIN/v1/package/windows.msi" 2>/dev/null || true)
    if [ -n "$status" ]; then
        remote_sha=$(printf '%s\n' "$status" | sed -n 's/^sha256=//p')
        local_sha=$(shasum -a 256 "$MSI" | cut -d' ' -f1)
        if [ "$remote_sha" = "$local_sha" ]; then
            return 0
        fi
    fi
    response=$(curl -fsS --max-time 180 -H "Authorization: Bearer $CFG_ADMIN_TOKEN" --data-binary @"$MSI" "$CFG_JOIN/v1/package/windows.msi" 2>/dev/null) ||
        die "上传 WireGuard 安装包失败，请检查维护 VPS 的 TCP 8443 是否放行。"
    printf '已上传 WireGuard 安装包。\n'
}

issue_code() {
    local sshkey response
    sshkey=$(awk '{print $1" "$2}' "$KEY")
    [ -n "$sshkey" ] || die "SSH 公钥文件内容无效：$KEY"
    response=$(curl -fsS --max-time 10 -H "Authorization: Bearer $CFG_ADMIN_TOKEN" \
        --data-urlencode "os=$PLATFORM" --data-urlencode "ssh=$sshkey" \
        "$CFG_JOIN/v1/invite" 2>/dev/null) ||
        die "维护 VPS 签发邀请失败，请确认服务已启动。"
    CODE=$(printf '%s\n' "$response" | sed -n 's/^code=//p')
    [ -n "$CODE" ] || die "维护 VPS 返回的邀请格式不正确。"
}

print_reports() {
    local line created code encoded
    curl -fsS --max-time 8 -H "Authorization: Bearer $CFG_ADMIN_TOKEN" "$CFG_JOIN/v1/reports" >/tmp/wgmaint-reports.txt 2>/dev/null ||
        die "读取客户机诊断报告失败。"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        created=$(printf '%s' "$line" | cut -d' ' -f1)
        code=$(printf '%s' "$line" | cut -d' ' -f2)
        encoded=$(printf '%s' "$line" | cut -d' ' -f3)
        printf '%s %s %s\n' "$created" "$code" "$(printf '%s' "$encoded" | base64 -D 2>/dev/null || printf '%s' "$encoded" | base64 -d)"
    done </tmp/wgmaint-reports.txt
}

if [ "$REPORTS" -eq 1 ]; then
    if ! load_config; then
        die "这台 Mac 还没有登记这台维护 VPS。"
    fi
    print_reports
    exit 0
fi

if ! load_config; then
    CFG_JOIN=""
    CFG_ENDPOINT=""
    CFG_NETWORK=""
    CFG_SERVER_PUB=""
    CFG_ADMIN_IP=""
    CFG_ADMIN_KEY=""
    CFG_ADMIN_TOKEN=""
    rm -f "$config" "$admin_conf" 2>/dev/null || true
fi
if [ -z "$CFG_JOIN" ]; then
    obtain_registration
    apply_registration "$REGISTER"
fi
status_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $CFG_ADMIN_TOKEN" "$CFG_JOIN/v1/status" 2>/dev/null || true)
if [ "$status_code" != "200" ]; then
    printf '维护 VPS 已重新登记，正在更新本机配置。\n'
    rm -f "$config" "$admin_conf" 2>/dev/null || true
    CFG_JOIN=""
    obtain_registration
    apply_registration "$REGISTER"
    wg_quick_path=$(command -v wg-quick || true)
    if [ "$SKIP_WG" -eq 0 ] && [ -n "$wg_quick_path" ] && sudo -n true >/dev/null 2>&1; then
        sudo -n "$wg_quick_path" down "$admin_conf" >/dev/null 2>&1 || true
    fi
fi
ensure_tunnel
ensure_package
issue_code

COMMAND="powershell -NoExit -c \"try{iex(irm '$CFG_JOIN/j/$CODE')}catch{Write-Host '接入失败：无法下载接入脚本，请检查网络后重试。' -ForegroundColor Red;Read-Host '按回车关闭窗口'}\""
length=$(printf '%s' "$COMMAND" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
[ "$length" -le 259 ] || die "Windows 接入命令超过 259 字符。"

if [ "$COPY" -eq 1 ]; then
    printf '%s' "$COMMAND" | pbcopy
    notify "已复制 Windows 接入命令（2 小时内有效）。到客户机粘贴执行，结束后从这台 Mac 执行 ssh -p 2222 wgmaint-ssh@隧道IP 登录。"
    printf '已复制 Windows 接入命令（%s 字符）。\n' "$length"
else
    printf '%s\n' "$COMMAND"
fi

bash -c 'if (( EUID == 0 )); then exec bash -s; fi; exec sudo bash -s' <<'WGMAINT_SHORT_SETUP'
set -Eeuo pipefail
umask 077
die() { printf '%s\n' "$*" >&2; exit 1; }

service=wgmaint-registry.service
app=/usr/local/lib/wgmaint
state=/var/lib/wgmaint
dropin=/etc/systemd/system/$service.d/short-join.conf
module=$app/registry_download.py
bootstrap=$app/customer-join-template.sh
systemctl is-active --quiet "$service" ||
    die '找不到正在运行的维护登记服务，请在已部署的维护 VPS 上执行。'
[[ -f $app/registry.py && -f $state/settings.json && -f $state/join.crt ]] ||
    die '维护 VPS 缺少接入服务文件。'
exec 9>/run/lock/wgmaint-short-join.lock
flock -n 9 || die '正在安装短命令入口，请稍后重试。'

unit=$(systemctl show -p FragmentPath --value "$service")
mapfile -t launchers < <(sed -n 's/^ExecStart=\(.*\/gunicorn .* \)registry:application$/\1registry_download:application/p' "$unit")
(( ${#launchers[@]} == 1 )) || die '登记服务启动配置与预期不符，升级已停止。'

work=$(mktemp -d)
changed=false
files=("$module" "$bootstrap" "$dropin")
rollback() {
    local status=$? i
    trap - EXIT
    if (( status != 0 )) && $changed; then
        printf '短命令入口安装失败，正在恢复原来的登记服务。\n' >&2
        for i in "${!files[@]}"; do
            if [[ -f $work/old.$i ]]; then
                cp -p -- "$work/old.$i" "${files[i]}" || true
            else
                rm -f -- "${files[i]}" || true
            fi
        done
        systemctl daemon-reload || true
        systemctl restart "$service" || true
    fi
    rm -rf -- "$work"
    exit "$status"
}
trap rollback EXIT

cat >"$work/registry_download.py" <<'WGMAINT_DOWNLOAD_PY'
import base64
import json
from contextlib import closing
from pathlib import Path
import re
import sqlite3
import time

from registry import application as registry_app, config, db_connect, digest, file_value

MARKER = b"WGMAINT_JOIN_DATA_PLACEHOLDER"
TEMPLATE = Path(__file__).with_name("customer-join-template.sh").read_bytes()
if TEMPLATE.count(MARKER) != 1:
    raise RuntimeError("invalid customer bootstrap template")


def response(start_response, status, body, content_type="text/plain; charset=utf-8"):
    start_response(status, [
        ("Content-Type", content_type),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
    ])
    return [body]


def application(environ, start_response):
    if environ.get("PATH_INFO") != "/v1/join.sh":
        return registry_app(environ, start_response)
    if environ.get("REQUEST_METHOD") == "HEAD":
        return response(start_response, "200 OK", b"")
    if environ.get("REQUEST_METHOD") != "GET":
        return response(start_response, "405 Method Not Allowed", b"GET required\n")
    auth = re.fullmatch(r"Bearer ([A-Za-z0-9_-]{43})", environ.get("HTTP_AUTHORIZATION", ""))
    if not auth:
        return response(start_response, "403 Forbidden", b"invalid invitation\n")
    ssh_key = environ.get("HTTP_X_WGMAINT_SSH_KEY", "")
    if not re.fullmatch(r"(?:ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+", ssh_key):
        return response(start_response, "400 Bad Request", b"invalid SSH public key\n")
    token = auth[1]
    try:
        with closing(db_connect()) as db:
            row = db.execute("SELECT expires FROM invitations WHERE digest = ?", (digest(token),)).fetchone()
        if not row or row[0] <= time.time():
            return response(start_response, "403 Forbidden", b"expired or invalid invitation\n")
        data = {
            **config(), "url": f"https://{config()['endpoint'].rsplit(':', 1)[0]}:8443/v1/enroll",
            "token": token, "certificate": file_value("join.crt") + "\n",
            "expires_at": row[0], "ssh_public_key": ssh_key,
        }
        payload = base64.b64encode(json.dumps(data, sort_keys=True).encode())
    except (OSError, sqlite3.Error, ValueError):
        return response(start_response, "503 Service Unavailable", b"retry later\n")
    return response(start_response, "200 OK", TEMPLATE.replace(MARKER, payload))
WGMAINT_DOWNLOAD_PY

cat >"$work/customer-join-template.sh" <<'WGMAINT_DOWNLOAD_SH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
trap 'printf "客户接入失败。出错行 %s，退出码 %s。\n" "$LINENO" "$?" >&2' ERR
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 && $(uname -s) == Linux && -d /run/systemd/system ]] ||
    die '请在使用 systemd 的 Linux 客户机上以 root 或 sudo 执行。'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die '客户机脚本支持 Debian 和 Ubuntu。'
exec 9>/run/lock/wgmaint-client.lock
flock -n 9 || die '已有一个客户接入任务在运行。'

WGMAINT_APT_REGION=cn
state=/var/lib/wgmaint-client
iface=wgmaintc0
account=wgmaint-ssh
wg_unit=wg-quick@$iface.service
ssh_unit=wgmaint-client-sshd.service
conf=/etc/wireguard/$iface.conf
install -d -m 0700 "$state"
join_tmp=$(mktemp -d)
policy=/usr/sbin/policy-rc.d
policy_owned=false
if [[ $policy -ef $state/package-policy ]]; then
    policy_owned=true
fi
cleanup() {
    if [[ -f $state/disable-stock-ssh ]]; then
        disable_stock_ssh >/dev/null 2>&1 || true
    fi
    if $policy_owned && [[ $policy -ef $state/package-policy ]]; then
        rm -f -- "$policy"
    fi
    rm -rf -- "$join_tmp"
}
trap cleanup EXIT
check_null_device() {
    [[ -c /dev/null && $(stat -Lc '%t:%T' /dev/null) == 1:3 ]] ||
        die '/dev/null 的设备类型或编号有误，应为字符设备 1:3。请先修复本机设备节点。'
    if [[ $(stat -Lc '%a' /dev/null) != 666 ]]; then
        printf '正在将 /dev/null 的权限恢复为 0666。\n' >&2
        chmod 0666 /dev/null
    fi
    if getent passwd _apt >/dev/null; then
        runuser -u _apt -- sh -c ': </dev/null && : >/dev/null' ||
            die 'APT 沙箱用户无法读写 /dev/null。请检查本机设备权限或访问限制。'
    fi
}

source_files=()
for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if [[ -r $source_file ]]; then
        source_files+=("$source_file")
    fi
done
has_mirror() {
    (( ${#source_files[@]} )) &&
        grep -Eiq "^[[:space:]]*(deb[[:space:]]|URIs:).*https?://($1)/" "${source_files[@]}"
}

aliyun_ecs=false
if grep -iq 'Alibaba Cloud' /sys/class/dmi/id/sys_vendor 2>/dev/null ||
    has_mirror 'mirrors\.(cloud\.)?aliyuncs\.com'; then
    aliyun_ecs=true
fi

apt_region=${WGMAINT_APT_REGION:-auto}
case "$apt_region" in
    auto)
        if has_mirror 'mirrors\.aliyun\.com|mirrors\.(cloud\.)?aliyuncs\.com|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn|mirrors\.huaweicloud\.com|mirrors\.cloud\.tencent\.com|mirrors\.tencent\.com'; then
            apt_region=cn
        else
            apt_region=system
        fi
        ;;
    cn|system) ;;
    *) die 'WGMAINT_APT_REGION 只接受 auto、cn 或 system。' ;;
esac

write_mirror_sources() {
    local mirror=$1 codename=$2 keyring=$3 archive
    if [[ $ID == debian ]]; then
        if [[ $codename == bullseye ]]; then
            # Only the frozen Bullseye security archive needs an exception to metadata expiry.
            printf 'deb [signed-by=%s] %s/debian-archive/debian/ %s main\n' "$keyring" "$mirror" "$codename"
            printf 'deb [signed-by=%s check-valid-until=no] %s/debian-archive/debian-security/ %s-security main\n' "$keyring" "$mirror" "$codename"
        else
            printf 'deb [signed-by=%s] %s/debian/ %s main\n' "$keyring" "$mirror" "$codename"
            printf 'deb [signed-by=%s] %s/debian-security/ %s-security main\n' "$keyring" "$mirror" "$codename"
        fi
    else
        case "$(dpkg --print-architecture)" in
            amd64|i386) archive=ubuntu ;;
            *) archive=ubuntu-ports ;;
        esac
        for suite in "$codename" "$codename-updates" "$codename-security"; do
            printf 'deb [signed-by=%s] %s/%s/ %s main universe\n' "$keyring" "$mirror" "$archive" "$suite"
        done
    fi
}

install_from_cn_mirrors() (
    local codename=${VERSION_CODENAME:-} keyring mirror attempt apt_tmp
    local -a apt_options mirrors
    [[ $codename =~ ^[a-z][a-z0-9]*$ ]] || die '无法从 /etc/os-release 读取发行版代号。'
    keyring=/usr/share/keyrings/$ID-archive-keyring.gpg
    [[ -s $keyring ]] || die "缺少发行版软件源签名密钥环 $keyring。"
    mirrors=(https://mirrors.aliyun.com https://mirrors.tuna.tsinghua.edu.cn)
    if [[ $ID == debian && $codename == bullseye ]]; then
        mirrors=(https://mirrors.aliyun.com https://repo.huaweicloud.com/repository)
    fi
    if $aliyun_ecs && has_mirror 'mirrors\.cloud\.aliyuncs\.com'; then
        mirrors=(http://mirrors.cloud.aliyuncs.com "${mirrors[@]}")
    fi
    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        printf '本机缺少 CA 证书，首次取包使用 HTTP，仍校验发行版签名。\n'
        mirrors=("${mirrors[@]/https:/http:}")
    fi

    apt_tmp=$(mktemp -d /tmp/wgmaint-apt.XXXXXX)
    trap 'rm -rf -- "$apt_tmp"' EXIT
    chmod 0755 "$apt_tmp"
    attempt=0
    for mirror in "${mirrors[@]}"; do
        attempt=$((attempt + 1))
        local mirror_dir=$apt_tmp/$attempt
        install -d -m 0755 "$mirror_dir" "$mirror_dir/lists" "$mirror_dir/archives"
        write_mirror_sources "$mirror" "$codename" "$keyring" >"$mirror_dir/sources.list"
        chmod 0644 "$mirror_dir/sources.list"
        apt_options=(
            -o "Dir::Etc::sourcelist=$mirror_dir/sources.list"
            -o Dir::Etc::sourceparts=-
            -o "Dir::State::lists=$mirror_dir/lists"
            -o "Dir::Cache::archives=$mirror_dir/archives"
            -o APT::Update::Error-Mode=any
            -o Acquire::Languages=none
            -o Acquire::Retries=1
            -o Acquire::ForceIPv4=true
            -o Acquire::http::Timeout=8
            -o Acquire::https::Timeout=8
            -o Acquire::http::Pipeline-Depth=0
            -o Acquire::AllowInsecureRepositories=false
            -o APT::Get::AllowUnauthenticated=false
        )
        printf '正在使用 APT 镜像 %s（%s）。\n' "$mirror" "$codename"
        if apt-get "${apt_options[@]}" update </dev/null &&
            apt-get "${apt_options[@]}" --download-only -y --no-remove --no-install-recommends install "$@" </dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" --no-download -y --no-remove --no-install-recommends install "$@" </dev/null
            return
        fi
        printf 'APT 镜像访问或取包失败：%s\n' "$mirror" >&2
    done
    die '国内 APT 镜像均未能完成取包，请查看上方的 APT 报错。'
)


check_null_device
export NEEDRESTART_MODE=l

installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]
}
packages=(wireguard-tools iproute2 ca-certificates curl python3 openssh-server openssh-client)
missing=()
for package in "${packages[@]}"; do
    if ! installed "$package"; then missing+=("$package"); fi
done

disable_stock_ssh() {
    local unit
    for unit in ssh.socket ssh.service; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            systemctl disable --now "$unit"
        fi
    done
}

if ! installed openssh-server; then
    for unit in ssh.service ssh.socket; do
        if systemctl is-active --quiet "$unit"; then
            die '检测到独立安装的 SSH 服务，请先确认本机的 OpenSSH 软件包状态。'
        fi
    done
    cat >"$state/package-policy" <<'PACKAGE_POLICY'
#!/bin/sh
[ "${1:-}" != --quiet ] || shift
case "${1##*/}" in
    ssh|sshd|ssh.service|sshd.service|ssh.socket|sshd.socket|ssh@.service) exit 101 ;;
esac
exit 0
PACKAGE_POLICY
    chmod 0700 "$state/package-policy"
    if [[ ! -e $policy && ! -L $policy ]]; then
        ln -s "$state/package-policy" "$policy" ||
            die '无法建立临时 SSH 启动保护，请检查 /usr/sbin/policy-rc.d。'
    fi
    if [[ $policy -ef $state/package-policy ]]; then
        policy_owned=true
    else
        for unit in ssh ssh.service ssh.socket; do
            rc=0
            "$policy" "$unit" start >/dev/null 2>&1 || rc=$?
            [[ $rc == 101 ]] || die '已有的 policy-rc.d 未阻止默认 SSH 启动，安装已暂停。'
        done
    fi
    : >"$state/disable-stock-ssh"
fi
if (( ${#missing[@]} )); then
    printf '正在补齐 WireGuard 和 OpenSSH 依赖。\n'
    install_from_cn_mirrors "${missing[@]}"
fi
if [[ -f $state/disable-stock-ssh ]]; then
    disable_stock_ssh
    rm -f -- "$state/disable-stock-ssh"
fi
if $policy_owned && [[ $policy -ef $state/package-policy ]]; then
    rm -f -- "$policy"
    policy_owned=false
fi

if [[ ! -s $state/client.key ]]; then
    wg genkey >"$join_tmp/client.key"
    install -m 0600 "$join_tmp/client.key" "$state/client.key"
fi
public_key=$(wg pubkey <"$state/client.key")
export WGMAINT_JOIN_DATA='WGMAINT_JOIN_DATA_PLACEHOLDER'
python3 - "$join_tmp" "$state" "$public_key" <<'PREPARE'
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

temp, state = map(Path, sys.argv[1:3])
pub = sys.argv[3]

def fail(message):
    sys.exit(message)

try:
    data = json.loads(base64.b64decode(os.environ["WGMAINT_JOIN_DATA"], validate=True))
    url = urlsplit(data["url"])
    admin = ipaddress.IPv4Address(data["admin_ip"])
    if (url.scheme != "https" or url.port != 8443 or url.path != "/v1/enroll"
        or url.username is not None or url.password is not None or url.query or url.fragment):
        fail("邀请中的登记地址格式有误。")
    host = url.hostname
    if not host or not re.fullmatch(r"[A-Za-z0-9.-]+", host) or data["endpoint"].lower() != host + ":51820":
        fail("邀请中的 WireGuard 公网入口与登记地址不一致。")
    for key in (data["server_public_key"], pub):
        raw = base64.b64decode(key, validate=True)
        if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != key:
            fail("WireGuard 公钥格式有误。")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", data["token"]):
        fail("邀请令牌格式有误。")
    cert = data["certificate"].strip()
    if not re.fullmatch(r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+\n-----END CERTIFICATE-----", cert):
        fail("邀请中的登记证书格式有误。")
    ssh_key = data["ssh_public_key"]
    if not re.fullmatch(r"(?:ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+", ssh_key):
        fail("SSH 公钥格式有误。")
    settings = {key: data[key] for key in ("endpoint", "server_public_key", "admin_ip", "ssh_public_key")}
    existing = state / "peer.json"
    if existing.exists():
        previous = json.loads(existing.read_text())
        if any(previous.get(key) != value for key, value in settings.items()):
            fail("这台机器已配置其他维护入口或管理公钥。")
    elif data["expires_at"] <= time.time():
        fail("邀请已过期，请在 Mac 上生成新的接入命令。")
    (temp / "issuer.json").write_text(json.dumps(settings))
    (temp / "url").write_text(data["url"])
    (temp / "ca.pem").write_text(cert + "\n")
    (temp / "request.json").write_text(json.dumps({"token": data["token"], "public_key": pub}))
except (KeyError, ValueError, TypeError):
    fail("接入命令内的邀请数据无效。")
PREPARE
unset WGMAINT_JOIN_DATA
if [[ ! -f $state/peer.json ]]; then
    [[ ! -e $conf ]] || die "接口配置 $conf 已存在。为避免覆盖，接入已停止。"
    printf '正在向维护 VPS 登记 WireGuard 公钥。\n'
    mkdir "$join_tmp/empty-cas"
    http_status=$(curl -q -sS --noproxy '*' --connect-timeout 6 --max-time 18 \
        --cacert "$join_tmp/ca.pem" --capath "$join_tmp/empty-cas" -H 'Content-Type: application/json' \
        --data-binary @"$join_tmp/request.json" --output "$join_tmp/reply.json" \
        --write-out '%{http_code}' "$(cat "$join_tmp/url")") ||
        die '无法连接 VPS 的 HTTPS 登记端口。请检查客户机网络和 VPS 的 TCP 8443。'
    case "$http_status" in
        200) ;;
        403) die '邀请已过期、无效或已由另一台机器使用。请重新签发。' ;;
        503) die 'VPS 暂时未完成登记，可在邀请有效期内原样重试。' ;;
        *) die "VPS 拒绝登记，HTTP 状态码 $http_status。" ;;
    esac
    python3 - "$join_tmp" <<'REPLY'
import ipaddress
import json
from pathlib import Path
import sys

temp = Path(sys.argv[1])
try:
    settings = json.loads((temp / "issuer.json").read_text())
    reply = json.loads((temp / "reply.json").read_text())
    if any(reply.get(key) != settings[key] for key in ("endpoint", "server_public_key", "admin_ip")):
        raise ValueError()
    address = ipaddress.IPv4Interface(reply["address"])
    admin = ipaddress.IPv4Address(settings["admin_ip"])
    network = ipaddress.IPv4Network(f"{admin}/24", strict=False)
    if address.network.prefixlen != 32 or address.ip not in network or not 3 <= int(address.ip) - int(network.network_address) <= 254:
        raise ValueError()
    settings["address"] = str(address)
    (temp / "peer.json").write_text(json.dumps(settings) + "\n")
except (AttributeError, KeyError, ValueError, TypeError):
    sys.exit("VPS 返回的 WireGuard 配置无效。")
REPLY
    install -m 0600 "$join_tmp/peer.json" "$state/peer.json.tmp"
    mv -f "$state/peer.json.tmp" "$state/peer.json"
fi

mapfile -t values < <(python3 - "$state/peer.json" <<'VALUES'
import json
import sys
with open(sys.argv[1]) as file:
    record = json.load(file)
for key in ("endpoint", "server_public_key", "admin_ip", "address", "ssh_public_key"):
    print(record[key])
VALUES
)
[[ ${#values[@]} == 5 ]] || die '无法读取本机接入记录。'
endpoint=${values[0]} server_key=${values[1]} admin_ip=${values[2]} address=${values[3]} ssh_key=${values[4]}
client_ip=${address%/32}
install -d -m 0700 /etc/wireguard
if [[ ! -f $conf ]]; then
    cat >"$join_tmp/wg.conf" <<WG_CONFIG
[Interface]
PrivateKey = $(cat "$state/client.key")
Address = $address

[Peer]
PublicKey = $server_key
Endpoint = $endpoint
AllowedIPs = $admin_ip/32
PersistentKeepalive = 25
WG_CONFIG
    install -m 0600 "$join_tmp/wg.conf" "$conf"
fi
systemctl enable --now "$wg_unit"
[[ $(wg show "$iface" public-key) == "$public_key" ]] ||
    die '本机 WireGuard 接口与接入记录不匹配。'

if [[ ! -f $state/account ]]; then
    if getent passwd "$account" >/dev/null; then die "账户 $account 已存在，接入已停止。"; fi
    printf '%s\n' "$account" >"$state/account"
fi
if ! getent passwd "$account" >/dev/null; then
    useradd --create-home --user-group --shell /bin/bash "$account"
fi
account_home=$(getent passwd "$account" | cut -d: -f6)
[[ $account_home == /* && $account_home != / && -d $account_home ]] ||
    die '维护账号的主目录无效。'

printf '正在配置通过 WireGuard 访问的 SSH。\n'
if [[ ! -d /run/sshd ]]; then install -d -m 0755 /run/sshd; fi
if ! systemctl is-active --quiet "$ssh_unit" &&
    ssh-keyscan -T 2 -t ed25519,ecdsa,rsa "$client_ip" >"$join_tmp/hostkeys" 2>/dev/null; then
    if ! systemctl is-active --quiet ssh.service && ! systemctl is-active --quiet ssh.socket; then
        die '隧道地址的 22 端口已有其他 SSH 监听，请先确认其配置。'
    fi
    ssh_settings=$(/usr/sbin/sshd -T -C "user=$account,host=$admin_ip,addr=$admin_ip,laddr=$client_ip,lport=22")
    grep -qx 'pubkeyauthentication yes' <<<"$ssh_settings" ||
        die '现有 SSH 策略不允许维护账号使用公钥。'
    grep -Eq '^authorizedkeysfile (.* )?(\.ssh/authorized_keys|%h/\.ssh/authorized_keys)( |$)' <<<"$ssh_settings" ||
        die '现有 SSH 使用自定义公钥路径，请先确认其策略。'
    reuse=true
else
    reuse=false
fi

authorized_line="restrict,pty,from=\"$admin_ip\" $ssh_key wgmaint-client"
runuser -u "$account" -- sh -c '
    set -eu
    umask 077
    mkdir -p -- "$1/.ssh"
    chmod 0700 "$1/.ssh"
    keys=$1/.ssh/authorized_keys
    touch "$keys"
    chmod 0600 "$keys"
    grep -Fxq -- "$2" "$keys" || printf "%s\n" "$2" >>"$keys"
' sh "$account_home" "$authorized_line"

if ! $reuse; then
    if [[ ! -s $state/ssh_host_ed25519_key ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$state/ssh_host_ed25519_key"
    fi
    cat >"$join_tmp/sshd_config" <<SSH_CONFIG
Port 22
AddressFamily inet
ListenAddress $client_ip
HostKey $state/ssh_host_ed25519_key
PidFile /run/wgmaint-client-sshd.pid
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
UsePAM yes
AllowUsers $account@$admin_ip
AuthorizedKeysFile .ssh/authorized_keys
AllowTcpForwarding no
X11Forwarding no
Subsystem sftp internal-sftp
SSH_CONFIG
    /usr/sbin/sshd -t -f "$join_tmp/sshd_config"
    install -m 0600 "$join_tmp/sshd_config" "$state/sshd_config"
    cat >"$join_tmp/sshd.service" <<SSH_UNIT
[Unit]
Description=WireGuard 客户机维护 SSH
BindsTo=$wg_unit
PartOf=$wg_unit
After=$wg_unit ssh.service ssh.socket

[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -m 0755 /run/sshd
ExecStart=/usr/sbin/sshd -D -e -f $state/sshd_config
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SSH_UNIT
    install -m 0644 "$join_tmp/sshd.service" "/etc/systemd/system/$ssh_unit"
    systemctl daemon-reload
    systemctl enable --now "$ssh_unit"
fi

# Trigger a WireGuard packet even when the Mac is currently offline.
python3 - "$admin_ip" <<'KICKSTART'
import socket
import sys

try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(b"wgmaint", (sys.argv[1], 9))
except OSError:
    pass
KICKSTART
handshake=0
for (( attempt=0; attempt<12; attempt++ )); do
    handshake=$(wg show "$iface" latest-handshakes | awk -v peer="$server_key" '$1 == peer { print $2 }')
    if [[ $handshake =~ ^[0-9]+$ ]] && (( handshake > 0 && $(date +%s) - handshake < 180 )); then break; fi
    sleep 1
done
[[ $handshake =~ ^[0-9]+$ ]] && (( handshake > 0 && $(date +%s) - handshake < 180 )) ||
    die '配置已写入，但尚未与 VPS 完成 WireGuard 握手。请检查 VPS 的 UDP 51820 和客户机出站网络。'
ssh-keyscan -T 3 -t ed25519,ecdsa,rsa "$client_ip" >"$join_tmp/hostkeys" 2>/dev/null ||
    die 'WireGuard 已握手，但本机隧道地址上的 SSH 未响应。'

printf '\n客户机已加入隧道，SSH 在本机检查通过。\n'
printf '在已接入 WireGuard 的 Mac 上执行：ssh %s@%s\n' "$account" "$client_ip"
printf '首次连接请核对以下 SSH 主机指纹。\n'
ssh-keygen -lf "$join_tmp/hostkeys"

WGMAINT_DOWNLOAD_SH

bash -n "$work/customer-join-template.sh"
python3 - "$work/registry_download.py" <<'WGMAINT_CHECK_PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
compile(path.read_text(), str(path), "exec")
WGMAINT_CHECK_PY
printf '[Service]\nExecStart=\nExecStart=%s\n' "${launchers[0]}" >"$work/short-join.conf"

endpoint=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["endpoint"])' "$state/settings.json")
[[ $endpoint =~ ^[A-Za-z0-9.-]+$ ]] || die '维护 VPS 的公网入口配置无效。'
mkdir -p -- "$(dirname "$dropin")"
for i in "${!files[@]}"; do
    if [[ -e ${files[i]} ]]; then cp -p -- "${files[i]}" "$work/old.$i"; fi
done

put() {
    install -m 0644 "$1" "$2.wgmaint-new"
    mv -f -- "$2.wgmaint-new" "$2"
}
changed=true
put "$work/registry_download.py" "$module"
put "$work/customer-join-template.sh" "$bootstrap"
put "$work/short-join.conf" "$dropin"
systemctl daemon-reload
systemctl restart "$service"

for attempt in {1..12}; do
    status=$(curl -qsSI --noproxy '*' --max-time 2 --cacert "$state/join.crt" \
        --connect-to "$endpoint:8443:127.0.0.1:8443" --output /dev/null --write-out '%{http_code}' \
        "https://$endpoint:8443/v1/join.sh" 2>/dev/null) || status=000
    if [[ $status == 200 ]]; then
        printf '短命令入口已启用。现在可以回 Mac 点「新客户接入」。\n'
        exit 0
    fi
    sleep 1
done
die '本机检查未通过。'
WGMAINT_SHORT_SETUP

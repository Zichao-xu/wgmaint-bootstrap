bash -c 'if (( EUID == 0 )); then exec bash -s; fi; exec sudo env "SSH_CONNECTION=${SSH_CONNECTION:-}" "WGMAINT_ENDPOINT=${WGMAINT_ENDPOINT:-}" "WGMAINT_ADMIN_PUBLIC_KEY=${WGMAINT_ADMIN_PUBLIC_KEY:-}" "WGMAINT_APT_REGION=${WGMAINT_APT_REGION:-}" bash -s' <<'WGMAINT_DEPLOY'
set -Eeuo pipefail
umask 077
trap 'printf "部署失败。出错行 %s，退出码 %s。\n" "$LINENO" "$?" >&2' ERR

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '请在使用 systemd 的 Linux 服务器上执行。'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die '此脚本支持 Debian 和 Ubuntu。'
exec 9>/run/lock/wgmaint-deploy.lock
flock -n 9 || die '已有一个部署任务在运行。'

state=/var/lib/wgmaint
iface=wgmaint0
conf=/etc/wireguard/$iface.conf
settings=$state/settings.json
wg_port=51820
join_port=8443

put() {
    local target=$1 mode=$2 group=$3 tmp
    tmp=$(mktemp "${target}.XXXXXX")
    cat >"$tmp"
    chown "root:$group" "$tmp"
    chmod "$mode" "$tmp"
    if [[ -f $target && ! -L $target ]] && cmp -s "$tmp" "$target"; then
        chown "root:$group" "$target"
        chmod "$mode" "$target"
        rm -f "$tmp"
    else
        mv -f "$tmp" "$target"
    fi
}

check_null_device() {
    [[ -c /dev/null && $(stat -Lc '%t:%T' /dev/null) == 1:3 ]] ||
        die '/dev/null 的设备类型或编号有误，应为字符设备 1:3。请先修复 VPS 的设备节点。'
    if [[ $(stat -Lc '%a' /dev/null) != 666 ]]; then
        printf '正在将 /dev/null 的权限恢复为 0666。\n' >&2
        chmod 0666 /dev/null
    fi
    if getent passwd _apt >/dev/null; then
        runuser -u _apt -- sh -c ': </dev/null && : >/dev/null' ||
            die 'APT 沙箱用户无法读写 /dev/null。请检查 VPS 的设备权限或访问限制。'
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
packages=(wireguard-tools nftables iproute2 openssl curl python3 gunicorn)
missing=()
for package in "${packages[@]}"; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) != 'install ok installed' ]]; then
        missing+=("$package")
    fi
done
if (( ${#missing[@]} )); then
    if [[ $apt_region == cn ]]; then
        install_from_cn_mirrors "${missing[@]}"
    else
        apt-get update </dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" </dev/null
    fi
fi

if ! getent passwd wgmaint >/dev/null; then
    useradd --system --user-group --no-create-home --home-dir "$state" --shell /usr/sbin/nologin wgmaint
fi
install -d -m 0750 -o root -g wgmaint "$state"
install -d -m 0700 -o wgmaint -g wgmaint "$state/db"
install -d -m 0700 /etc/wireguard
install -d -m 0755 /usr/local/lib/wgmaint "/etc/systemd/system/wg-quick@$iface.service.d"

if [[ ! -f $settings ]]; then
    [[ ! -e $conf ]] || die "配置文件 $conf 已存在。为避免覆盖，部署已停止。"
    if ip link show dev "$iface" >/dev/null 2>&1; then
        die "网络接口 $iface 已存在。"
    fi
    if nft list table inet wgmaint >/dev/null 2>&1; then
        die 'nftables 中已存在名为 wgmaint 的规则表。'
    fi
    if [[ -n $(ss -H -lun "sport = :$wg_port") || -n $(ss -H -ltn "sport = :$join_port") ]]; then
        die "端口冲突。部署需要 UDP $wg_port 和 TCP $join_port。"
    fi
    discovered=$(/usr/bin/python3 - "${WGMAINT_ENDPOINT:-}" "${SSH_CONNECTION:-}" "$aliyun_ecs" <<'DISCOVER'
import ipaddress
import json
import re
import subprocess
import sys

def aliyun_public_ip():
    root = "http://100.100.100.200/latest"
    curl = ["curl", "-q", "-fsS", "--noproxy", "*", "--connect-timeout", "1",
            "--max-time", "2", "--max-filesize", "1024"]
    try:
        token = subprocess.check_output(
            [*curl, "-X", "PUT", "-H", "X-aliyun-ecs-metadata-token-ttl-seconds: 60",
             root + "/api/token"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return ""
    if not token or not re.fullmatch(r"[!-~]+", token):
        return ""
    for name in ("eipv4", "public-ipv4"):
        try:
            response = subprocess.check_output(
                [*curl, "-H", "@-", root + "/meta-data/" + name], text=True,
                input="X-aliyun-ecs-metadata-token: " + token + "\n", stderr=subprocess.DEVNULL
            ).strip()
            ip = ipaddress.IPv4Address(response)
            if ip.is_global and not ip.is_multicast:
                return str(ip)
        except (ValueError, OSError, subprocess.SubprocessError):
            continue
    return ""


endpoint, ssh, aliyun_ecs = sys.argv[1:]
if not endpoint:
    addresses = {
        ipaddress.IPv4Address(info["local"])
        for device in json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show", "scope", "global"]))
        for info in device.get("addr_info", [])
    }
    public = {ip for ip in addresses if ip.is_global and not ip.is_multicast}
    fields = ssh.split()
    if len(fields) == 4 and fields[2] in {str(ip) for ip in public}:
        endpoint = fields[2]
    elif len(public) == 1:
        endpoint = str(next(iter(public)))
    elif aliyun_ecs == "true":
        endpoint = aliyun_public_ip()
    if not endpoint:
        sys.exit("无法自动识别公网 IPv4。请通过 WGMAINT_ENDPOINT 指定公网 IP 或域名后重试。")
try:
    ip = ipaddress.IPv4Address(endpoint)
except ValueError:
    labels = endpoint.split(".")
    if (len(endpoint) > 253 or len(labels) < 2 or not any(c.isalpha() for c in labels[-1])
        or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels)):
        sys.exit("WGMAINT_ENDPOINT 需要填写 IPv4 地址或域名。")
    san = "DNS:" + endpoint
else:
    if not ip.is_global or ip.is_multicast:
        sys.exit("WGMAINT_ENDPOINT 需要填写公网单播 IPv4 地址。")
    san = "IP:" + endpoint
routes = [
    ipaddress.IPv4Network(row["dst"], strict=False)
    for row in json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "show", "table", "all"]))
    if row.get("dst") not in (None, "default")
]
for prefix in ("10.203.249", "10.239.246", "172.30.231", "192.168.237"):
    net = ipaddress.IPv4Network(prefix + ".0/24")
    if all(not net.overlaps(route) for route in routes):
        print(json.dumps({"endpoint": endpoint, "san": san, "network": str(net)}))
        break
else:
    sys.exit("候选隧道网段均与 VPS 的现有路由冲突。")
DISCOVER
    )
    put "$settings" 0640 wgmaint <<<"$discovered"
fi

mapfile -t values < <(/usr/bin/python3 - "$settings" <<'SETTINGS'
import ipaddress
import json
import sys

s = json.load(open(sys.argv[1]))
n = ipaddress.IPv4Network(s["network"])
for value in (s["endpoint"], s["san"], str(n), n[1], n[2]):
    print(value)
SETTINGS
)
[[ ${#values[@]} == 5 ]] || die '无法读取部署配置。'
endpoint=${values[0]} san=${values[1]} network=${values[2]} vps_ip=${values[3]} admin_ip=${values[4]}
if [[ -n ${WGMAINT_ENDPOINT:-} && $endpoint != "$WGMAINT_ENDPOINT" ]]; then
    die "现有部署使用的公网入口是 $endpoint。"
fi

if [[ ! -s $state/server.key ]]; then
    key=$(wg genkey)
    put "$state/server.key" 0600 root <<<"$key"
fi
key=$(wg pubkey <"$state/server.key")
put "$state/server.pub" 0640 wgmaint <<<"$key"

if [[ ! -s $state/admin.pub ]]; then
    if [[ -n ${WGMAINT_ADMIN_PUBLIC_KEY:-} ]]; then
        key=$(/usr/bin/python3 - "$WGMAINT_ADMIN_PUBLIC_KEY" <<'ADMINKEY'
import base64
import sys

key = sys.argv[1]
try:
    raw = base64.b64decode(key, validate=True)
except ValueError:
    sys.exit("WGMAINT_ADMIN_PUBLIC_KEY 不是有效的 WireGuard 公钥。")
if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != key:
    sys.exit("WGMAINT_ADMIN_PUBLIC_KEY 不是有效的 WireGuard 公钥。")
print(key)
ADMINKEY
        )
        put "$state/admin.pub" 0640 wgmaint <<<"$key"
    else
        if [[ ! -s $state/admin.key ]]; then
            key=$(wg genkey)
            put "$state/admin.key" 0600 root <<<"$key"
        fi
        key=$(wg pubkey <"$state/admin.key")
        put "$state/admin.pub" 0640 wgmaint <<<"$key"
    fi
fi
if [[ -n ${WGMAINT_ADMIN_PUBLIC_KEY:-} && $(cat "$state/admin.pub") != "$WGMAINT_ADMIN_PUBLIC_KEY" ]]; then
    die '提供的管理端公钥与现有部署记录不一致。'
fi
[[ $(cat "$state/admin.pub") != "$(cat "$state/server.pub")" ]] || die '管理端和服务器必须使用不同的 WireGuard 公钥。'

if [[ ! -s $state/join.crt || ! -s $state/join.key ]]; then
    cert_tmp=$(mktemp -d "$state/cert.XXXXXX")
    openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj '/CN=wgmaint-enrollment' -addext "subjectAltName=$san" \
        -addext 'basicConstraints=critical,CA:FALSE' -addext 'extendedKeyUsage=serverAuth' \
        -keyout "$cert_tmp/key" -out "$cert_tmp/cert" >/dev/null 2>&1
    put "$state/join.key" 0640 wgmaint <"$cert_tmp/key"
    put "$state/join.crt" 0640 wgmaint <"$cert_tmp/cert"
    rm -rf -- "$cert_tmp"
fi

put "$conf" 0600 root <<WGCONF
[Interface]
Address = $vps_ip/24
ListenPort = $wg_port
PrivateKey = $(cat "$state/server.key")
PostUp = /sbin/sysctl -qw net.ipv4.conf.%i.forwarding=1
PostUp = /sbin/sysctl -qw net.ipv4.conf.%i.send_redirects=0

[Peer]
PublicKey = $(cat "$state/admin.pub")
AllowedIPs = $admin_ip/32
WGCONF

if [[ -s $state/admin.key ]]; then
    put "$state/admin.conf" 0600 root <<ADMINCONF
[Interface]
PrivateKey = $(cat "$state/admin.key")
Address = $admin_ip/32

[Peer]
PublicKey = $(cat "$state/server.pub")
Endpoint = $endpoint:$wg_port
AllowedIPs = $network
PersistentKeepalive = 25
ADMINCONF
    rm -f -- "$state/admin.key"
fi

put "$state/firewall.nft" 0600 root <<RULES
add table inet wgmaint
delete table inet wgmaint
table inet wgmaint {
    chain input {
        type filter hook input priority -10; policy accept;
        iifname "$iface" ip saddr $admin_ip ip daddr $vps_ip icmp type echo-request accept
        iifname "$iface" drop
    }
    chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "$iface" oifname "$iface" ip saddr $admin_ip ip daddr $network tcp dport 22 ct state { new, established } accept
        iifname "$iface" oifname "$iface" ip saddr $network ip daddr $admin_ip tcp sport 22 ct state established accept
        iifname "$iface" drop
        oifname "$iface" drop
    }
    chain output {
        type filter hook output priority -10; policy accept;
        oifname "$iface" ip protocol icmp icmp type redirect drop
    }
}
RULES
nft -c -f "$state/firewall.nft"

put /usr/local/lib/wgmaint/registry.py 0644 root <<'REGISTRY'
import base64
import hashlib
import ipaddress
import json
import re
import secrets
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path

STATE = Path("/var/lib/wgmaint")
IFACE = "wgmaint0"
JOIN_PORT = 8443
WG_PORT = 51820
TTL = 900
MAX_BODY = 1024


class RequestError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message


def settings():
    return json.loads((STATE / "settings.json").read_text())


def db_connect():
    connection = sqlite3.connect(STATE / "db" / "registry.sqlite", timeout=5)
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def init_db():
    with closing(db_connect()) as db, db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS peers (
                public_key TEXT PRIMARY KEY,
                address TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS invitations (
                digest TEXT PRIMARY KEY,
                expires INTEGER NOT NULL,
                public_key TEXT REFERENCES peers (public_key)
            );
        """)


def wg(*args):
    return subprocess.check_output(["/usr/bin/wg", *args], timeout=5, text=True).strip()


def file_value(name):
    return (STATE / name).read_text().strip()


def config():
    data = settings()
    network = ipaddress.IPv4Network(data["network"])
    return {
        "endpoint": f"{data['endpoint']}:{WG_PORT}",
        "server_public_key": file_value("server.pub"),
        "admin_ip": str(network[2]),
    }


def apply_peer(key, address):
    wg("set", IFACE, "peer", key, "allowed-ips", address + "/32")


def restore_peers():
    with closing(db_connect()) as db:
        for key, address in db.execute("SELECT public_key, address FROM peers"):
            apply_peer(key, address)


def digest(token):
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def invite():
    token = secrets.token_urlsafe(32)
    now = int(time.time())
    expires = now + TTL
    with closing(db_connect()) as db, db:
        db.execute("DELETE FROM invitations WHERE expires <= ?", (now,))
        db.execute("INSERT INTO invitations VALUES (?, ?, NULL)", (digest(token), expires))
    print(json.dumps({
        **config(),
        "url": f"https://{settings()['endpoint']}:{JOIN_PORT}/v1/enroll",
        "certificate": file_value("join.crt") + "\n",
        "token": token,
        "expires_at": expires,
    }, indent=2))


def valid_key(key):
    if not isinstance(key, str) or len(key) != 44:
        return False
    try:
        raw = base64.b64decode(key, validate=True)
    except ValueError:
        return False
    return len(raw) == 32 and any(raw) and base64.b64encode(raw).decode() == key


def enroll(payload):
    if not isinstance(payload, dict):
        raise RequestError("400 Bad Request", "invalid payload")
    token, key = payload.get("token"), payload.get("public_key")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
        raise RequestError("403 Forbidden", "invalid or expired invitation")
    if not valid_key(key) or key in (file_value("server.pub"), file_value("admin.pub")):
        raise RequestError("400 Bad Request", "invalid peer public key")

    token_digest = digest(token)
    with closing(db_connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute(
            "SELECT expires, public_key FROM invitations WHERE digest = ?", (token_digest,)
        ).fetchone()
        if not row or row[0] <= time.time() or row[1] not in (None, key):
            raise RequestError("403 Forbidden", "invalid or expired invitation")
        existing = db.execute("SELECT address FROM peers WHERE public_key = ?", (key,)).fetchone()
        if existing:
            address = existing[0]
        else:
            network = ipaddress.IPv4Network(settings()["network"])
            used = {row[0] for row in db.execute("SELECT address FROM peers")}
            address = next((str(network[i]) for i in range(3, 255) if str(network[i]) not in used), None)
            if address is None:
                raise RequestError("409 Conflict", "address pool exhausted")
            db.execute("INSERT INTO peers VALUES (?, ?)", (key, address))
        db.execute("UPDATE invitations SET public_key = ? WHERE digest = ?", (key, token_digest))

    # Persist first so a failed kernel update can be retried by the same peer.
    apply_peer(key, address)
    return {**config(), "address": address + "/32"}


def application(environ, start_response):
    route = environ["REQUEST_METHOD"], environ["PATH_INFO"]
    status = "200 OK"
    try:
        if route == ("GET", "/healthz"):
            result = {"ready": True}
        elif route == ("POST", "/v1/enroll"):
            length = int(environ.get("CONTENT_LENGTH") or 0)
            if not 0 < length <= MAX_BODY:
                raise RequestError("400 Bad Request", "invalid body length")
            result = enroll(json.loads(environ["wsgi.input"].read(length)))
        else:
            raise RequestError("404 Not Found", "not found")
    except RequestError as exc:
        status, result = exc.status, {"error": exc.message}
    except (ValueError, UnicodeError):
        status, result = "400 Bad Request", {"error": "invalid JSON"}
    except (OSError, sqlite3.Error, subprocess.SubprocessError, RuntimeError) as exc:
        print(f"接入登记服务出错：{type(exc).__name__}", file=sys.stderr)
        status, result = "503 Service Unavailable", {"error": "retry later"}

    body = json.dumps(result).encode("utf-8") + b"\n"
    start_response(status, [("Content-Type", "application/json"),
                            ("Content-Length", str(len(body))),
                            ("Cache-Control", "no-store")])
    return [body]


if __name__ == "__main__":
    if sys.argv[1:] == ["restore"]:
        init_db()
        restore_peers()
    elif sys.argv[1:] == ["invite"]:
        invite()
    else:
        sys.exit("用法：registry.py restore|invite")
REGISTRY

put /etc/systemd/system/wgmaint-firewall.service 0644 root <<FIREWALL_UNIT
[Unit]
Description=WireGuard 维护网络防火墙
After=nftables.service ufw.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f $state/firewall.nft
RemainAfterExit=yes
FIREWALL_UNIT

put "/etc/systemd/system/wg-quick@$iface.service.d/wgmaint.conf" 0644 root <<'WG_UNIT'
[Unit]
Requires=wgmaint-firewall.service
After=wgmaint-firewall.service
WG_UNIT

put /etc/systemd/system/wgmaint-registry.service 0644 root <<REGISTRY_UNIT
[Unit]
Description=WireGuard 客户接入登记服务
BindsTo=wg-quick@$iface.service
After=wg-quick@$iface.service
PartOf=wg-quick@$iface.service

[Service]
User=wgmaint
Group=wgmaint
WorkingDirectory=/usr/local/lib/wgmaint
ExecStartPre=/usr/bin/python3 /usr/local/lib/wgmaint/registry.py restore
ExecStart=/usr/bin/gunicorn --bind 0.0.0.0:$join_port --workers 2 --timeout 12 --limit-request-line 1024 --limit-request-fields 24 --limit-request-field_size 2048 --certfile $state/join.crt --keyfile $state/join.key registry:application
Restart=on-failure
RestartSec=2
UMask=0077
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$state/db
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
REGISTRY_UNIT

systemctl daemon-reload
if ! nft list table inet wgmaint >/dev/null 2>&1; then
    systemctl restart wgmaint-firewall.service
fi
systemctl enable --now "wg-quick@$iface.service" wgmaint-registry.service

ready=0
for (( attempt=0; attempt<15; attempt++ )); do
    if curl --silent --fail --noproxy '*' --max-time 2 --cacert "$state/join.crt" \
        --connect-to "$endpoint:$join_port:127.0.0.1:$join_port" \
        "https://$endpoint:$join_port/healthz" >/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
(( ready )) || die '接入登记服务本机检查失败。运行 journalctl -u wgmaint-registry.service -n 50 查看日志。'
[[ $(wg show "$iface" listen-port) == "$wg_port" ]] || die 'WireGuard 监听端口检查失败。'
[[ $(wg show "$iface" public-key) == "$(cat "$state/server.pub")" ]] || die 'WireGuard 服务器公钥检查失败。'

invitation=$(runuser -u wgmaint -- /usr/bin/python3 /usr/local/lib/wgmaint/registry.py invite)
put "$state/latest-invite.json" 0600 root <<<"$invitation"
printf '\n部署完成，服务已通过本机检查。\n'
printf 'WireGuard 公网入口：%s:%s（UDP）\n客户接入地址：https://%s:%s（TCP）\n' "$endpoint" "$wg_port" "$endpoint" "$join_port"
printf 'VPS 隧道 IP：%s\n管理端隧道 IP：%s\n' "$vps_ip" "$admin_ip"
if [[ -f $state/admin.conf ]]; then
    printf 'Mac 的 WireGuard 配置（含私钥）：%s/admin.conf\n' "$state"
else
    printf '服务器 WireGuard 公钥：%s\n管理端 AllowedIPs：%s\n' "$(cat "$state/server.pub")" "$network"
fi
printf '最新客户接入邀请（15 分钟内有效）：%s/latest-invite.json\n' "$state"
printf '请确认 VPS 防火墙和云安全组放行入站 UDP %s、TCP %s，并允许管理端通过 %s 转发 SSH 到客户机。\n' "$wg_port" "$join_port" "$iface"
WGMAINT_DEPLOY

bash -c 'if [ "$(id -u)" = 0 ]; then exec bash -s; fi; exec sudo env WGMAINT_APT_REGION="$WGMAINT_APT_REGION" WGMAINT_ENDPOINT="$WGMAINT_ENDPOINT" SSH_CONNECTION="$SSH_CONNECTION" bash -s' <<'WGMAINT_DEPLOY'
set -Eeo pipefail
umask 077
trap 'printf "部署失败：第 %s 行，退出码 %s。\n" "$LINENO" "$?" >&2' ERR
die() { printf '%s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '请在使用 systemd 的 Debian 或 Ubuntu 上执行。'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die '仅支持 Debian 和 Ubuntu。'
exec 9>/run/lock/wgmaint-deploy.lock
flock -n 9 || die '已有一个部署任务在运行。'

state=/var/lib/wgmaint
iface=wgmaint0
wg_port=51820
join_port=8443
settings=$state/settings.json

put() {
    local target=$1 mode=$2 group=$3 tmp
    tmp=$(mktemp "$target.XXXXXX")
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
        die '/dev/null 的设备类型或编号有误，应为字符设备 1:3。'
    if [[ $(stat -Lc '%a' /dev/null) != 666 ]]; then
        printf '正在将 /dev/null 的权限恢复为 0666。\n' >&2
        chmod 0666 /dev/null
    fi
    if getent passwd _apt >/dev/null; then
        runuser -u _apt -- sh -c ': </dev/null && : >/dev/null' ||
            die 'APT 沙箱用户无法读写 /dev/null。'
    fi
}

install_packages() {
    local package missing count=0
    for package in "$@"; do
        if ! dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed'; then
            missing="$missing $package"
            count=$((count + 1))
        fi
    done
    (( count )) || return 0
    printf '正在安装依赖：%s\n' "$missing"
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -qq </dev/null && apt-get install -y --no-install-recommends $missing </dev/null; then
        return 0
    fi
    apt_region=$WGMAINT_APT_REGION
    [ -n "$apt_region" ] || apt_region=auto
    [[ $apt_region == system ]] && die 'APT 安装失败。请检查 VPS 的软件源。'
    printf '默认软件源失败，改用国内镜像重试。\n'
    local codename=$VERSION_CODENAME keyring mirror dir archive suite
    [[ $codename =~ ^[a-z][a-z0-9]*$ ]] || die '无法从 /etc/os-release 读取发行版代号。'
    keyring=/usr/share/keyrings/$ID-archive-keyring.gpg
    [[ -s $keyring ]] || die "缺少软件源签名密钥环 $keyring。"
    for mirror in https://mirrors.aliyun.com https://mirrors.tuna.tsinghua.edu.cn; do
        dir=$(mktemp -d)
        mkdir -p "$dir/lists" "$dir/archives"
        if [[ $ID == debian ]]; then
            if [[ $codename == bullseye ]]; then
                printf 'deb [signed-by=%s] %s/debian-archive/debian/ %s main\n' "$keyring" "$mirror" "$codename" >"$dir/sources.list"
                printf 'deb [signed-by=%s check-valid-until=no] %s/debian-archive/debian-security/ %s-security main\n' "$keyring" "$mirror" "$codename" >>"$dir/sources.list"
            else
                printf 'deb [signed-by=%s] %s/debian/ %s main\n' "$keyring" "$mirror" "$codename" >"$dir/sources.list"
                printf 'deb [signed-by=%s] %s/debian-security/ %s-security main\n' "$keyring" "$mirror" "$codename" >>"$dir/sources.list"
            fi
        else
            case "$(dpkg --print-architecture)" in
                amd64|i386) archive=ubuntu ;;
                *) archive=ubuntu-ports ;;
            esac
            : >"$dir/sources.list"
            for suite in "$codename" "$codename-updates" "$codename-security"; do
                printf 'deb [signed-by=%s] %s/%s/ %s main universe\n' "$keyring" "$mirror" "$archive" "$suite" >>"$dir/sources.list"
            done
        fi
        if apt-get -o "Dir::Etc::sourcelist=$dir/sources.list" -o Dir::Etc::sourceparts=- \
            -o "Dir::State::lists=$dir/lists" -o "Dir::Cache::archives=$dir/archives" \
            -o APT::Update::Error-Mode=any -o Acquire::Languages=none -o Acquire::Retries=1 \
            -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
            -o Acquire::http::Pipeline-Depth=0 -o APT::Get::AllowUnauthenticated=false \
            update -qq </dev/null &&
            apt-get -o "Dir::Etc::sourcelist=$dir/sources.list" -o Dir::Etc::sourceparts=- \
            -o "Dir::State::lists=$dir/lists" -o "Dir::Cache::archives=$dir/archives" \
            -o APT::Get::AllowUnauthenticated=false \
            install -y --no-install-recommends $missing </dev/null; then
            rm -rf -- "$dir"
            return 0
        fi
        rm -rf -- "$dir"
        printf '镜像访问失败：%s\n' "$mirror" >&2
    done
    die '国内 APT 镜像均未能完成安装。'
}

check_null_device
install_packages wireguard-tools nftables iproute2 python3 curl

printf '正在清理旧部署（如有）。\n'
systemctl disable --now wgmaint-registry.service 2>/dev/null || true
systemctl disable --now wgmaint-firewall.service 2>/dev/null || true
rm -f /etc/systemd/system/wgmaint-registry.service /etc/systemd/system/wgmaint-firewall.service
rm -rf /etc/systemd/system/wgmaint-registry.service.d
systemctl stop "wg-quick@$iface.service" 2>/dev/null || true
wg-quick down "$iface" 2>/dev/null || true
rm -f "$state/join.crt" "$state/join.key" "$state/admin.key" "$state/latest-invite.json"
rm -rf "$state/db"
rm -f /usr/local/lib/wgmaint/registry.py /usr/local/lib/wgmaint/registry_windows.py \
    /usr/local/lib/wgmaint/registry_download.py /usr/local/lib/wgmaint/customer-join-windows.ps1 \
    /usr/local/lib/wgmaint/windows-bootstrap.ps1
systemctl daemon-reload 2>/dev/null || true

if ! getent passwd wgmaint >/dev/null; then
    useradd --system --user-group --no-create-home --home-dir "$state" --shell /usr/sbin/nologin wgmaint
fi
install -d -m 0750 -o root -g wgmaint "$state"
install -d -m 0750 -o wgmaint -g wgmaint "$state/db" "$state/pkg"
install -d -m 0700 /etc/wireguard
install -d -m 0755 /usr/local/lib/wgmaint "/etc/systemd/system/wg-quick@$iface.service.d"

aliyun_ecs=false
if grep -iq 'Alibaba Cloud' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    aliyun_ecs=true
fi

if [[ ! -f $settings ]]; then
    [[ ! -e /etc/wireguard/$iface.conf ]] || die "配置文件 /etc/wireguard/$iface.conf 已存在但缺少设置记录，已停止。"
    discovered=$(/usr/bin/python3 - "$WGMAINT_ENDPOINT" "$SSH_CONNECTION" "$aliyun_ecs" <<'DISCOVER'
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


command_line, ssh, aliyun_ecs = sys.argv[1], sys.argv[2], sys.argv[3]
endpoint = command_line.strip()
if not endpoint:
    addresses = {
        ipaddress.IPv4Address(info["local"])
        for device in json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show", "scope", "global"]))
        for info in device.get("addr_info", [])
    }
    public = set(ip for ip in addresses if ip.is_global and not ip.is_multicast)
    fields = ssh.split()
    if len(fields) == 4 and fields[2] in set(str(ip) for ip in public):
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
        print(json.dumps({"endpoint": endpoint, "network": str(net)}))
        break
else:
    sys.exit("候选隧道网段均与 VPS 的现有路由冲突。")
DISCOVER
    )
    put "$settings" 0640 wgmaint <<<"$discovered"
fi

read -r endpoint network vps_ip admin_ip < <(/usr/bin/python3 - "$settings" <<'SETTINGS'
import ipaddress
import json
import sys

s = json.load(open(sys.argv[1]))
n = ipaddress.IPv4Network(s["network"])
print(s["endpoint"], str(n), n[1], n[2])
SETTINGS
)
[[ -n $endpoint && -n $network && -n $vps_ip && -n $admin_ip ]] || die '无法读取部署配置。'
if [[ -n $WGMAINT_ENDPOINT && $endpoint != "$WGMAINT_ENDPOINT" ]]; then
    die "现有部署使用的公网入口是 $endpoint。"
fi

if [[ ! -s $state/server.key ]]; then
    key=$(wg genkey)
    put "$state/server.key" 0600 root <<<"$key"
fi
wg pubkey <"$state/server.key" | put "$state/server.pub" 0640 wgmaint

admin_key=$(wg genkey)
admin_pub=$(printf '%s\n' "$admin_key" | wg pubkey)
put "$state/admin.pub" 0640 wgmaint <<<"$admin_pub"
put "$state/admin.conf" 0640 wgmaint <<ADMINCONF
[Interface]
PrivateKey = $admin_key
Address = $admin_ip/32

[Peer]
PublicKey = $(cat "$state/server.pub")
Endpoint = $endpoint:$wg_port
AllowedIPs = $network
PersistentKeepalive = 25
ADMINCONF

admin_token=$(/usr/bin/python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
put "$state/admin.token" 0640 wgmaint <<<"$admin_token"

put "/etc/wireguard/$iface.conf" 0600 root <<WGCONF
[Interface]
Address = $vps_ip/24
ListenPort = $wg_port
PrivateKey = $(cat "$state/server.key")
PostUp = /sbin/sysctl -qw net.ipv4.conf.%i.forwarding=1
PostUp = /sbin/sysctl -qw net.ipv4.conf.%i.send_redirects=0
PostUp = /sbin/sysctl -qw net.ipv4.ip_forward=1

[Peer]
PublicKey = $admin_pub
AllowedIPs = $admin_ip/32
WGCONF

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
        iifname "$iface" oifname "$iface" ip saddr $admin_ip ip daddr $network tcp dport { 22, 2222 } ct state { new, established } accept
        iifname "$iface" oifname "$iface" ip saddr $network ip daddr $admin_ip tcp sport { 22, 2222 } ct state established accept
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
import hmac
import ipaddress
import json
import re
import secrets
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

STATE = Path("/var/lib/wgmaint")
IFACE = "wgmaint0"
PORT = 8443
WG_PORT = 51820
TTL = 7200
MAX_UPLOAD = 80 * 1024 * 1024
PKG_NAMES = ("windows.msi", "openssh.zip")
PKG_DIR = STATE / "pkg"
SERVER_VERSION = "wgmaint/2"


def settings():
    return json.loads((STATE / "settings.json").read_text())


def db_connect():
    connection = sqlite3.connect(str(STATE / "db" / "registry.sqlite"), timeout=10)
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def init_db():
    with closing(db_connect()) as db, db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS codes (
                code TEXT PRIMARY KEY,
                os TEXT NOT NULL,
                ssh_key TEXT NOT NULL,
                expires INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS peers (
                public_key TEXT PRIMARY KEY,
                address TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT NOT NULL,
                message TEXT NOT NULL,
                created INTEGER NOT NULL
            );
        """)


def origin():
    return "http://" + settings()["endpoint"] + ":" + str(PORT)


def server_public_key():
    return (STATE / "server.pub").read_text().strip()


def admin_ip():
    return str(ipaddress.IPv4Network(settings()["network"])[2])


def wg_apply(public_key, address):
    subprocess.run(
        ["/usr/bin/wg", "set", IFACE, "peer", public_key,
         "allowed-ips", str(ipaddress.IPv4Address(address)) + "/32"],
        check=True, timeout=10,
    )


def restore_peers():
    with closing(db_connect()) as db:
        for public_key, address in db.execute("SELECT public_key, address FROM peers"):
            wg_apply(public_key, address)


def package_path(name):
    return PKG_DIR / name


def package_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def valid_public_key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9+/]{43}=", value):
        return False
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        return False
    return len(raw) == 32 and any(raw)


def valid_ssh_key(value):
    return isinstance(value, str) and bool(
        re.fullmatch(r"(?:ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa) [A-Za-z0-9+/=]{16,1200}", value)
    )


class Handler(BaseHTTPRequestHandler):
    server_version = SERVER_VERSION

    def log_message(self, *args):
        pass

    def send_body(self, status, body=b"", content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def form(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if not 0 < length <= 16384:
            return None
        try:
            raw = self.rfile.read(length).decode("utf-8")
        except UnicodeError:
            return None
        return {key: value[0] for key, value in parse_qs(raw).items()}

    def authorized(self):
        match = re.fullmatch(r"Bearer ([A-Za-z0-9_-]{43})", self.headers.get("Authorization") or "")
        if not match:
            return False
        return hmac.compare_digest(match.group(1), (STATE / "admin.token").read_text().strip())

    def report(self):
        form = self.form()
        if form is None:
            return self.send_body(400, b"bad request\n")
        code = form.get("code", "")
        message = form.get("message", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{22}", code) or not message:
            return self.send_body(400, b"bad request\n")
        message = message[:4000]
        with closing(db_connect()) as db:
            if not db.execute("SELECT 1 FROM codes WHERE code = ?", (code,)).fetchone():
                return self.send_body(403, b"forbidden\n")
        with closing(db_connect()) as db, db:
            db.execute("INSERT INTO reports (code, message, created) VALUES (?, ?, ?)",
                       (code, message, int(time.time())))
        return self.send_body(200, b"ok\n")

    def reports(self):
        if not self.authorized():
            return self.send_body(403, b"forbidden\n")
        lines = []
        with closing(db_connect()) as db:
            for created, code, message in db.execute(
                    "SELECT created, code, message FROM reports ORDER BY id DESC LIMIT 20"):
                encoded = base64.b64encode(message.encode("utf-8")).decode("ascii")
                lines.append("%d %s %s\n" % (created, code, encoded))
        return self.send_body(200, "".join(lines).encode("ascii"))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        try:
            if path == "/healthz":
                return self.send_body(200, b"ok\n")
            if path == "/v1/status":
                if not self.authorized():
                    return self.send_body(403, b"forbidden\n")
                return self.send_body(200, b"ok\n")
            if path == "/v1/reports":
                return self.reports()
            match = re.fullmatch(r"/v1/package/([A-Za-z0-9.]+)", path)
            if match and match.group(1) in PKG_NAMES:
                if not self.authorized():
                    return self.send_body(403, b"forbidden\n")
                package = package_path(match.group(1))
                if not package.is_file():
                    return self.send_body(404, b"missing\n")
                status = "size=%d\nsha256=%s\n" % (package.stat().st_size, package_digest(package))
                return self.send_body(200, status.encode("ascii"))
            match = re.fullmatch(r"/j/([A-Za-z0-9_-]{22})", path)
            if match:
                return self.join_script(match.group(1))
            match = re.fullmatch(r"/j/([A-Za-z0-9_-]{22})/pkg/([A-Za-z0-9.]+)", path)
            if match and match.group(2) in PKG_NAMES:
                return self.package(match.group(1), match.group(2))
            return self.send_body(404, b"not found\n")
        except OSError as error:
            print("读取文件失败：%s" % type(error).__name__, file=sys.stderr)
            return self.send_body(500, b"error\n")

    def do_POST(self):
        path = urlsplit(self.path).path
        try:
            if path == "/v1/invite":
                return self.invite()
            if path == "/v1/enroll":
                return self.enroll()
            if path == "/v1/report":
                return self.report()
            match = re.fullmatch(r"/v1/package/([A-Za-z0-9.]+)", path)
            if match and match.group(1) in PKG_NAMES:
                return self.upload(match.group(1))
            return self.send_body(404, b"not found\n")
        except (ValueError, UnicodeError):
            return self.send_body(400, b"bad request\n")
        except (OSError, sqlite3.Error, subprocess.SubprocessError) as error:
            print("服务内部错误：%s" % type(error).__name__, file=sys.stderr)
            return self.send_body(503, b"retry later\n")

    def join_script(self, code):
        with closing(db_connect()) as db:
            row = db.execute("SELECT os, ssh_key, expires FROM codes WHERE code = ?", (code,)).fetchone()
        if not row or row[2] <= time.time():
            return self.send_body(404, b"expired\n")
        if row[0] != "windows":
            return self.send_body(404, b"unsupported\n")
        msi = package_path("windows.msi")
        ssh = package_path("openssh.zip")
        if not msi.is_file() or not ssh.is_file():
            return self.send_body(503, b"package missing\n")
        template = Path(__file__).with_name("join-windows.ps1").read_text()
        body = (template
                .replace("__JOIN__", origin())
                .replace("__CODE__", code)
                .replace("__SSHKEY__", row[1])
                .replace("__MSISIZE__", str(msi.stat().st_size))
                .replace("__MSISHA__", package_digest(msi))
                .replace("__SSHSIZE__", str(ssh.stat().st_size))
                .replace("__SSHSHA__", package_digest(ssh)))
        return self.send_body(200, body.encode("ascii"))

    def package(self, code, name):
        with closing(db_connect()) as db:
            row = db.execute("SELECT expires FROM codes WHERE code = ?", (code,)).fetchone()
        if not row or row[0] <= time.time():
            return self.send_body(404, b"expired\n")
        path = package_path(name)
        if not path.is_file():
            return self.send_body(503, b"package missing\n")
        return self.send_body(200, path.read_bytes(), "application/octet-stream")

    def invite(self):
        if not self.authorized():
            return self.send_body(403, b"forbidden\n")
        form = self.form()
        if form is None:
            return self.send_body(400, b"bad request\n")
        os_name = form.get("os", "")
        ssh_key = form.get("ssh", "")
        if os_name not in ("windows", "mac") or not valid_ssh_key(ssh_key):
            return self.send_body(400, b"bad request\n")
        code = secrets.token_urlsafe(16)
        expires = int(time.time()) + TTL
        with closing(db_connect()) as db, db:
            db.execute("INSERT INTO codes VALUES (?, ?, ?, ?)", (code, os_name, ssh_key, expires))
        body = "code=%s\nexpires_at=%d\n" % (code, expires)
        return self.send_body(200, body.encode("ascii"))

    def enroll(self):
        form = self.form()
        if form is None:
            return self.send_body(400, b"bad request\n")
        code = form.get("code", "")
        public_key = form.get("public_key", "")
        if not valid_public_key(public_key):
            return self.send_body(400, b"bad request\n")
        now = time.time()
        with closing(db_connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT expires FROM codes WHERE code = ?", (code,)).fetchone()
            if not row or row[0] <= now:
                return self.send_body(403, b"expired\n")
            existing = db.execute("SELECT address FROM peers WHERE public_key = ?", (public_key,)).fetchone()
            if existing:
                address = existing[0]
            else:
                network = ipaddress.IPv4Network(settings()["network"])
                used = set(record[0] for record in db.execute("SELECT address FROM peers"))
                address = None
                for index in range(3, 255):
                    candidate = str(network[index])
                    if candidate not in used:
                        address = candidate
                        break
                if address is None:
                    return self.send_body(409, b"full\n")
                db.execute("INSERT INTO peers VALUES (?, ?)", (public_key, address))
            wg_apply(public_key, address)
        body = "address=%s/32\nendpoint=%s:%d\nserver_public_key=%s\nadmin_ip=%s\n" % (
            address, settings()["endpoint"], WG_PORT, server_public_key(), admin_ip())
        return self.send_body(200, body.encode("ascii"))

    def upload(self, name):
        if not self.authorized():
            return self.send_body(403, b"forbidden\n")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self.send_body(400, b"bad request\n")
        if not 0 < length <= MAX_UPLOAD:
            return self.send_body(400, b"bad request\n")
        data = self.rfile.read(length)
        if len(data) != length:
            return self.send_body(400, b"short read\n")
        package = package_path(name)
        temporary = PKG_DIR / (".upload-" + secrets.token_hex(6))
        temporary.write_bytes(data)
        temporary.chmod(0o640)
        package.write_bytes(data)
        package.chmod(0o640)
        temporary.unlink(missing_ok=True)
        status = "size=%d\nsha256=%s\n" % (len(data), hashlib.sha256(data).hexdigest())
        return self.send_body(200, status.encode("ascii"))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "invite":
        sys.stdout.write((STATE / "register.txt").read_text())
        return
    init_db()
    restore_peers()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
REGISTRY

put /usr/local/lib/wgmaint/join-windows.ps1 0644 root <<'WINDOWS_PS'
# Wgmaint Windows onboarding. ASCII only; Chinese text is Base64 UTF-8.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$join = '__JOIN__'
$code = '__CODE__'
$sshKey = '__SSHKEY__'
$msiSha = '__MSISHA__'
$msiSize = __MSISIZE__
$sshZipSha = '__SSHSHA__'
$sshZipSize = __SSHSIZE__
$stage = 'start'

function T([string] $value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
$M_ELEVATE = '5q2j5Zyo6K+35rGC566h55CG5ZGY5p2D6ZmQ77yM6K+35Zyo5by556qX5Lit54K544CM5piv44CN44CC'
$M_OS = '6ZyA6KaBIFdpbmRvd3MgMTAgMTgwOSDmiJbmm7TmlrDnmoQgNjQg5L2N57O757uf44CC'
$M_WG = '5q2j5Zyo5a6J6KOFIFdpcmVHdWFyZC4uLg=='
$M_ENROLL = '5q2j5Zyo55m76K6w6Zqn6YGTLi4u'
$M_SSH = '5q2j5Zyo6YWN572uIFNTSC4uLg=='
$M_OK = '5o6l5YWl5oiQ5Yqf77yB5Zyo57u05oqkIE1hYyDkuIrmiafooYzvvJo='
$M_REBOOT = '5a6J6KOF6ZyA6KaB6YeN5ZCv44CC6K+36YeN5ZCv55S16ISR5ZCO6YeN5paw57KY6LS05ZCM5LiA5p2h5ZG95Luk44CC'
$M_HANDSHAKE = 'V2lyZUd1YXJkIOacquWujOaIkOaPoeaJi++8jOivt+ajgOafpeWuouaIt+acuue9kee7nOWQjumHjeaWsOeymOi0tOWQjOS4gOadoeWRveS7pOOAgg=='
$M_SSH_FAIL = 'T3BlblNTSCDmnI3liqHlmajlkK/liqjlpLHotKXjgII='
$M_FAIL = '5o6l5YWl5aSx6LSl44CC'
$M_ACCOUNT = '57u05oqk6LSm5Y+35bey5a2Y5Zyo5L2G5LiN5Y+X5pys5bel5YW3566h55CG77yM5bey5YGc5q2i44CC'
$M_MSI_BAD = 'V2lyZUd1YXJkIOWuieijheWMheagoemqjOWksei0pe+8jOivt+mHjeaWsOeymOi0tOWQjOS4gOadoeWRveS7pOOAgg=='
$M_WG_FAIL = 'V2lyZUd1YXJkIOWuieijheWksei0peOAgg=='
$M_STAGE = '5b2T5YmN5q2l6aqk77ya'
$M_PAUSE = '6K+35oyJ5Zue6L2m6ZSu5YWz6Zet56qX5Y+j44CC'
$M_TUNNEL_FAIL = 'V2lyZUd1YXJkIOmap+mBk+WuieijheWksei0peOAgg=='

function Report([string] $message) {
    try {
        $body = 'code=' + [Uri]::EscapeDataString($code) + '&message=' + [Uri]::EscapeDataString($message)
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method Post -Uri ($join + '/v1/report') -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    } catch {
    }
}

function Stop-WithPause([string] $message) {
    Write-Host ((T $M_FAIL) + $message) -ForegroundColor Red
    try { Set-Clipboard -Value $message | Out-Null } catch {
    }
    try { Read-Host (T $M_PAUSE) } catch {
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host (T $M_ELEVATE) -ForegroundColor Yellow
    try {
        $arguments = '-NoExit -Command "iex(irm ''' + $join + '/j/' + $code + ''')"'
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
    } catch {
        Stop-WithPause $_.Exception.Message
    }
    exit
}

try {
    Report ('start build=' + [Environment]::OSVersion.Version.Build + ' ps=' + $PSVersionTable.PSVersion)
    $stage = 'check'
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or
        [Environment]::OSVersion.Version.Build -lt 17763) {
        throw (T $M_OS)
    }

    $root = Join-Path $env:ProgramData 'Wgmaint'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    $stage = 'wireguard'
    Write-Host (T $M_WG)
    $wg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    $wireguard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    if (-not (Test-Path -LiteralPath $wg)) {
        $msi = Join-Path $root 'wireguard.msi'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($join + '/j/' + $code + '/pkg/windows.msi') -OutFile $msi
            if ((Get-Item -LiteralPath $msi).Length -ne $msiSize) { throw (T $M_MSI_BAD) }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $msi).Hash -ne $msiSha) { throw (T $M_MSI_BAD) }
            $installer = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru
            if ($installer.ExitCode -eq 3010) { Write-Host (T $M_REBOOT) -ForegroundColor Yellow; Read-Host (T $M_PAUSE); exit 0 }
            if ($installer.ExitCode -ne 0) { throw ((T $M_WG_FAIL) + ' (' + $installer.ExitCode + ')') }
        } finally {
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $wg) -or -not (Test-Path -LiteralPath $wireguard)) { throw (T $M_WG_FAIL) }

    $stage = 'key'
    $keyFile = Join-Path $root 'wireguard.key'
    if (-not (Test-Path -LiteralPath $keyFile)) {
        $private = (& $wg genkey).Trim()
        if ($LASTEXITCODE -ne 0 -or $private -notmatch '^[A-Za-z0-9+/]{43}=$') { throw (T $M_WG_FAIL) }
        [IO.File]::WriteAllText($keyFile, $private + [char]10)
    }
    $private = [IO.File]::ReadAllText($keyFile).Trim()
    $public = ($private | & $wg pubkey).Trim()
    if ($LASTEXITCODE -ne 0 -or $public -notmatch '^[A-Za-z0-9+/]{43}=$') { throw (T $M_WG_FAIL) }

    $stage = 'enroll'
    Write-Host (T $M_ENROLL)
    $body = 'code=' + [Uri]::EscapeDataString($code) + '&public_key=' + [Uri]::EscapeDataString($public)
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($join + '/v1/enroll') -ContentType 'application/x-www-form-urlencoded' -Body $body
    $values = @{}
    foreach ($line in [Regex]::Split($response.Content, '[\r\n]+')) {
        if ($line -match '^([a-z_]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
    }
    if (-not $values['address'] -or -not $values['server_public_key'] -or
        -not $values['admin_ip'] -or -not $values['endpoint']) { throw (T $M_FAIL) }

    $stage = 'tunnel'
    $tunnel = 'wgmaint-customer'
    $serviceName = 'WireGuardTunnel$' + $tunnel
    $config = Join-Path $root ($tunnel + '.conf')
    $text = @"
[Interface]
PrivateKey = $private
Address = $($values['address'])

[Peer]
PublicKey = $($values['server_public_key'])
AllowedIPs = $($values['admin_ip'])/32
Endpoint = $($values['endpoint'])
PersistentKeepalive = 25
"@
    [IO.File]::WriteAllText($config, $text)

    $driver = Get-Service -Name 'WireGuard' -ErrorAction SilentlyContinue
    if ($driver -and $driver.Status -ne 'Running') {
        try { Start-Service -Name 'WireGuard' -ErrorAction Stop } catch {
        }
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        & $wireguard /uninstalltunnelservice $tunnel | Out-Null
        Start-Sleep -Seconds 2
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        & sc.exe delete $serviceName | Out-Null
        Start-Sleep -Seconds 1
    }
    $installOut = Join-Path $root 'tunnel-install.out'
    $installErr = Join-Path $root 'tunnel-install.err'
    $install = Start-Process -FilePath $wireguard -ArgumentList @('/installtunnelservice', $config) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $installOut -RedirectStandardError $installErr
    if ($install.ExitCode -ne 0) {
        $detail = ''
        foreach ($file in @($installOut, $installErr)) {
            if (Test-Path -LiteralPath $file) {
                $detail = $detail + (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue)
            }
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) { $detail = $detail + ' service=' + $service.Status }
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddMinutes(-10)} -MaxEvents 200 -ErrorAction Stop |
                Where-Object { $_.ProviderName -match 'WireGuard|Service Control Manager' } |
                Select-Object -First 3
            foreach ($event in $events) { $detail = $detail + ' | ' + $event.ProviderName + ': ' + $event.Message }
        } catch {
        }
        throw ((T $M_TUNNEL_FAIL) + 'exit=' + $install.ExitCode + ' ' + $detail)
    }
    $address = $values['address'].Split('/')[0]
    $tunnelOk = $false
    foreach ($attempt in 1..45) {
        $handshake = & $wg show $tunnel latest-handshakes 2>$null
        if ($LASTEXITCODE -eq 0 -and $handshake -match '\s[1-9][0-9]*\s*$' -and
            (Get-NetIPAddress -IPAddress $address -ErrorAction SilentlyContinue)) { $tunnelOk = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $tunnelOk) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $state = 'unknown'
        if ($service) { $state = $service.Status }
        throw ((T $M_HANDSHAKE) + ' service=' + $state)
    }

    $stage = 'sshd'
    Write-Host (T $M_SSH)
    $sshd = Join-Path $root 'openssh\sshd.exe'
    $keygen = Join-Path $root 'openssh\ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $sshd) -or -not (Test-Path -LiteralPath $keygen)) {
        $zip = Join-Path $root 'openssh.zip'
        $folder = Join-Path $root 'openssh'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($join + '/j/' + $code + '/pkg/openssh.zip') -OutFile $zip
            if ((Get-Item -LiteralPath $zip).Length -ne $sshZipSize) { throw (T $M_SSH_FAIL) }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ne $sshZipSha) { throw (T $M_SSH_FAIL) }
            if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
            Move-Item -LiteralPath (Join-Path $root 'OpenSSH-Win64') -Destination $folder -Force
        } finally {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $sshd) -or -not (Test-Path -LiteralPath $keygen)) { throw (T $M_SSH_FAIL) }

    $stage = 'account'
    $account = 'wgmaint-ssh'
    $user = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
    $sidFile = Join-Path $root 'account.sid'
    if ($user -and (-not (Test-Path -LiteralPath $sidFile) -or [IO.File]::ReadAllText($sidFile) -ne $user.SID.Value)) {
        throw (T $M_ACCOUNT)
    }
    if (-not $user) {
        $random = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N') + 'Aa1!'
        $user = New-LocalUser -Name $account -Password (ConvertTo-SecureString $random -AsPlainText -Force) -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires
        [IO.File]::WriteAllText($sidFile, $user.SID.Value)
    }
    if (@(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $user.SID }).Count -gt 0) { throw (T $M_ACCOUNT) }
    if (@(Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object { $_.SID -eq $user.SID }).Count -eq 0) {
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
    }

    $stage = 'authorized_keys'
    $hostKey = Join-Path $root 'ssh_host_ed25519_key'
    if (-not (Test-Path -LiteralPath $hostKey)) {
        $created = Start-Process -FilePath $keygen -ArgumentList @('-q', '-t', 'ed25519', '-N', '""', '-f', $hostKey) -Wait -PassThru -NoNewWindow
        if ($created.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $hostKey)) { throw (T $M_SSH_FAIL) }
    }
    & takeown.exe /f $hostKey /a | Out-Null
    & icacls.exe $hostKey /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    $authorized = Join-Path $root 'authorized_keys'
    [IO.File]::WriteAllText($authorized, ('from="' + $values['admin_ip'] + '",restrict,pty ' + $sshKey + [char]10))
    & takeown.exe /f $authorized /a | Out-Null
    & icacls.exe $authorized /inheritance:r /grant:r ('*' + $user.SID.Value + ':R') /grant:r '*S-1-5-18:F' /grant:r '*S-1-5-32-544:F' | Out-Null

    $stage = 'sshd_config'
    $port = 2222
    $sshdConfig = Join-Path $root 'sshd_config'
    $hostPath = $hostKey.Replace('\', '/')
    $authorizedPath = $authorized.Replace('\', '/')
    $configText = @"
Port $port
AddressFamily inet
ListenAddress $address
HostKey "$hostPath"
AuthorizedKeysFile "$authorizedPath"
AllowUsers $account@$($values['admin_ip'])
AuthenticationMethods publickey
PasswordAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
UseDNS no
"@
    [IO.File]::WriteAllText($sshdConfig, $configText)
    & takeown.exe /f $sshdConfig /a | Out-Null
    & icacls.exe $sshdConfig /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    & $sshd -t -f $sshdConfig
    if ($LASTEXITCODE -ne 0) { throw (T $M_SSH_FAIL) }

    $stage = 'ssh-service'
    $logFile = Join-Path $root 'sshd.log'
    $sshData = Join-Path $env:ProgramData 'ssh'
    if (-not (Test-Path -LiteralPath $sshData)) { New-Item -ItemType Directory -Path $sshData | Out-Null }
    $taskName = 'Wgmaint OpenSSH'
    $oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($oldTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    $svcName = 'WgmaintSSH'
    $oldService = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($oldService) {
        & sc.exe stop $svcName | Out-Null
        Start-Sleep -Seconds 1
        & sc.exe delete $svcName | Out-Null
        Start-Sleep -Seconds 1
    }
    $oldRule = Get-NetFirewallRule -Name 'Wgmaint-SSH' -ErrorAction SilentlyContinue
    if ($oldRule) { $oldRule | Remove-NetFirewallRule }
    New-NetFirewallRule -Name 'Wgmaint-SSH' -DisplayName 'Wgmaint SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -LocalAddress $address -RemoteAddress $values['admin_ip'] -Program $sshd | Out-Null
    $sshdArgs = '-D -f "' + $sshdConfig + '" -E "' + $logFile + '"'
    $started = $false
    try {
        $action = New-ScheduledTaskAction -Execute $sshd -Argument $sshdArgs
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT30S'
        $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $taskSettings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        foreach ($attempt in 1..15) {
            if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $started = $true; break }
            Start-Sleep -Seconds 1
        }
    } catch {
    }
    if (-not $started) {
        & sc.exe create $svcName binPath= ('"' + $sshd + '" ' + $sshdArgs) start= auto obj= LocalSystem DisplayName= 'Wgmaint SSH' | Out-Null
        & sc.exe start $svcName | Out-Null
        foreach ($attempt in 1..15) {
            if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $started = $true; break }
            Start-Sleep -Seconds 1
        }
    }
    if (-not $started) {
        $detail = ''
        if (Test-Path -LiteralPath $logFile) { $detail = $detail + (Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue) }
        $taskInfo = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
        if ($taskInfo) { $detail = $detail + ' task=' + $taskInfo.LastTaskResult }
        $procs = Get-Process -Name sshd -ErrorAction SilentlyContinue
        if ($procs) { $detail = $detail + ' sshd_pid=' + ($procs.Id -join ',') }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) { $detail = $detail + ' service=' + $svc.Status }
        throw ((T $M_SSH_FAIL) + $detail)
    }
    Write-Host (T $M_OK) -ForegroundColor Green
    Write-Host ('ssh -p ' + $port + ' ' + $account + '@' + $address)
    Report ('ok ' + $address)
} catch {
    $detail = $_.Exception.Message
    Write-Host ((T $M_FAIL) + $detail) -ForegroundColor Red
    Write-Host ((T $M_STAGE) + $stage) -ForegroundColor Red
    Report ($stage + ': ' + $detail)
    try { Set-Clipboard -Value ($stage + ': ' + $detail) | Out-Null } catch {
    }
    try { Read-Host (T $M_PAUSE) } catch {
    }
}

WINDOWS_PS

put /usr/local/bin/wgmaint 0755 root <<'CLI'
#!/bin/bash
exec /usr/bin/python3 /usr/local/lib/wgmaint/registry.py "$@"
CLI

put /etc/systemd/system/wgmaint-firewall.service 0644 root <<'FIREWALL_UNIT'
[Unit]
Description=wgmaint firewall
After=nftables.service ufw.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /var/lib/wgmaint/firewall.nft
RemainAfterExit=yes
FIREWALL_UNIT

put "/etc/systemd/system/wg-quick@$iface.service.d/wgmaint.conf" 0644 root <<'WG_UNIT'
[Unit]
Requires=wgmaint-firewall.service
After=wgmaint-firewall.service
WG_UNIT

put /etc/systemd/system/wgmaint.service 0644 root <<SERVICE_UNIT
[Unit]
Description=wgmaint enrollment service
BindsTo=wg-quick@$iface.service
After=wg-quick@$iface.service

[Service]
User=wgmaint
Group=wgmaint
ExecStart=/usr/bin/python3 /usr/local/lib/wgmaint/registry.py serve
Restart=on-failure
RestartSec=2
UMask=0077
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$state
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

register_payload="version=2
join=http://$endpoint:$join_port
endpoint=$endpoint:$wg_port
network=$network
server_public_key=$(cat "$state/server.pub")
admin_ip=$admin_ip
admin_private_key=$admin_key
admin_token=$admin_token"
put "$state/register.txt" 0640 wgmaint <<<"$register_payload"

systemctl daemon-reload
if ! nft list table inet wgmaint >/dev/null 2>&1; then
    systemctl restart wgmaint-firewall.service
fi
systemctl enable --now "wg-quick@$iface.service"
systemctl enable --now wgmaint.service

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:$join_port/healthz" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
(( ready )) || die '登记服务本机检查失败。运行 journalctl -u wgmaint.service -n 50 查看日志。'
[[ $(wg show "$iface" listen-port) == "$wg_port" ]] || die 'WireGuard 监听端口检查失败。'

register_code="WM2:$(printf '%s\n' "$register_payload" | base64 | tr -d '\n')"
printf '\n部署完成，服务已通过本机检查。\n'
printf 'WireGuard 入口：%s:%s（UDP）\n客户接入入口：http://%s:%s（TCP）\n' "$endpoint" "$wg_port" "$endpoint" "$join_port"
printf 'VPS 隧道 IP：%s\n管理端隧道 IP：%s\n\n' "$vps_ip" "$admin_ip"
printf '登记码（复制下面这一整行，回 Mac 点「新客户接入」时粘贴一次）：\n%s\n\n' "$register_code"
printf '请确认云安全组放行入站 UDP %s、TCP %s。\n' "$wg_port" "$join_port"
WGMAINT_DEPLOY

bash -c 'if (( EUID == 0 )); then exec bash -s; fi; exec sudo env "SSH_CONNECTION=${SSH_CONNECTION:-}" "WGMAINT_ENDPOINT=${WGMAINT_ENDPOINT:-}" "WGMAINT_ADMIN_PUBLIC_KEY=${WGMAINT_ADMIN_PUBLIC_KEY:-}" bash -s' <<'WGMAINT_DEPLOY'
set -Eeuo pipefail
umask 077
trap 'printf "Deployment failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Linux && -d /run/systemd/system ]] || die 'Requires Linux with systemd.'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die 'This installer supports Debian and Ubuntu.'
exec 9>/run/lock/wgmaint-deploy.lock
flock -n 9 || die 'Another deployment is running.'

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

packages=(wireguard-tools nftables iproute2 openssl curl python3 gunicorn)
missing=()
for package in "${packages[@]}"; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) != 'install ok installed' ]]; then
        missing+=("$package")
    fi
done
if (( ${#missing[@]} )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi

if ! getent passwd wgmaint >/dev/null; then
    useradd --system --user-group --no-create-home --home-dir "$state" --shell /usr/sbin/nologin wgmaint
fi
install -d -m 0750 -o root -g wgmaint "$state"
install -d -m 0700 -o wgmaint -g wgmaint "$state/db"
install -d -m 0700 /etc/wireguard
install -d -m 0755 /usr/local/lib/wgmaint "/etc/systemd/system/wg-quick@$iface.service.d"

if [[ ! -f $settings ]]; then
    [[ ! -e $conf ]] || die "Refusing to overwrite existing $conf."
    if ip link show dev "$iface" >/dev/null 2>&1; then
        die "Interface $iface already exists."
    fi
    if nft list table inet wgmaint >/dev/null 2>&1; then
        die 'An nftables table named wgmaint already exists.'
    fi
    if [[ -n $(ss -H -lun "sport = :$wg_port") || -n $(ss -H -ltn "sport = :$join_port") ]]; then
        die "Port conflict. Need UDP $wg_port and TCP $join_port."
    fi
    discovered=$(/usr/bin/python3 - "${WGMAINT_ENDPOINT:-}" "${SSH_CONNECTION:-}" <<'DISCOVER'
import ipaddress
import json
import re
import subprocess
import sys

endpoint, ssh = sys.argv[1:]
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
    else:
        sys.exit("Cannot infer the public IPv4 endpoint. Prefix the deployment command with WGMAINT_ENDPOINT=PUBLIC_IP_OR_DNS.")
try:
    ip = ipaddress.IPv4Address(endpoint)
except ValueError:
    labels = endpoint.split(".")
    if (len(endpoint) > 253 or len(labels) < 2 or not any(c.isalpha() for c in labels[-1])
        or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels)):
        sys.exit("WGMAINT_ENDPOINT must be an IPv4 address or DNS name.")
    san = "DNS:" + endpoint
else:
    if not ip.is_global or ip.is_multicast:
        sys.exit("WGMAINT_ENDPOINT must be a public unicast IPv4 address.")
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
    sys.exit("All candidate tunnel subnets overlap existing VPS routes.")
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
[[ ${#values[@]} == 5 ]] || die 'Could not read deployment settings.'
endpoint=${values[0]} san=${values[1]} network=${values[2]} vps_ip=${values[3]} admin_ip=${values[4]}
if [[ -n ${WGMAINT_ENDPOINT:-} && $endpoint != "$WGMAINT_ENDPOINT" ]]; then
    die "Existing deployment uses $endpoint."
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
    sys.exit("Invalid WGMAINT_ADMIN_PUBLIC_KEY.")
if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != key:
    sys.exit("Invalid WGMAINT_ADMIN_PUBLIC_KEY.")
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
    die 'Existing deployment has a different admin public key.'
fi
[[ $(cat "$state/admin.pub") != "$(cat "$state/server.pub")" ]] || die 'Admin and server public keys must differ.'

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
PostUp = /usr/sbin/sysctl -qw net.ipv4.conf.%i.forwarding=1
PostUp = /usr/sbin/sysctl -qw net.ipv4.conf.%i.send_redirects=0

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
        print(f"Registry error: {type(exc).__name__}", file=sys.stderr)
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
        sys.exit("usage: registry.py restore|invite")
REGISTRY

put /etc/systemd/system/wgmaint-firewall.service 0644 root <<FIREWALL_UNIT
[Unit]
Description=WireGuard maintenance firewall
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
Description=WireGuard maintenance peer enrollment
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
(( ready )) || die 'Enrollment check failed. Inspect: journalctl -u wgmaint-registry.service -n 50'
[[ $(wg show "$iface" listen-port) == "$wg_port" ]] || die 'WireGuard listen-port check failed.'
[[ $(wg show "$iface" public-key) == "$(cat "$state/server.pub")" ]] || die 'WireGuard public-key check failed.'

invitation=$(runuser -u wgmaint -- /usr/bin/python3 /usr/local/lib/wgmaint/registry.py invite)
put "$state/latest-invite.json" 0600 root <<<"$invitation"
printf '\nWireGuard: %s:%s (UDP)\nEnrollment: https://%s:%s (TCP)\n' "$endpoint" "$wg_port" "$endpoint" "$join_port"
printf 'VPS tunnel IP: %s\nAdmin tunnel IP: %s\n' "$vps_ip" "$admin_ip"
if [[ -f $state/admin.conf ]]; then
    printf 'Mac WireGuard profile (contains private key): %s/admin.conf\n' "$state"
else
    printf 'Server WireGuard public key: %s\nAdmin AllowedIPs: %s\n' "$(cat "$state/server.pub")" "$network"
fi
printf 'Latest invitation (expires in 15 minutes): %s/latest-invite.json\n' "$state"
printf 'Ensure the VPS host/cloud firewall allows inbound UDP %s and TCP %s, and admin-to-client forwarding on %s.\n' "$wg_port" "$join_port" "$iface"
WGMAINT_DEPLOY

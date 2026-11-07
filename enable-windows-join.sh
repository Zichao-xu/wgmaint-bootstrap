bash -c 'if (( EUID == 0 )); then exec bash -s; fi; exec sudo bash -s' <<'WGMAINT_WINDOWS_SETUP'
set -Eeuo pipefail
umask 077
die() { printf '%s\n' "$*" >&2; exit 1; }

service=wgmaint-registry.service
app=/usr/local/lib/wgmaint
state=/var/lib/wgmaint
dropin=/etc/systemd/system/$service.d/short-join.conf
module=$app/registry_windows.py
bootstrap=$app/customer-join-windows.ps1
launcher=$app/windows-bootstrap.ps1
firewall=$state/firewall.nft
systemctl is-active --quiet "$service" ||
    die '找不到正在运行的维护登记服务，请在已部署的维护 VPS 上执行。'
[[ -f $app/registry.py && -f $state/settings.json && -f $state/join.crt ]] ||
    die '维护 VPS 缺少接入服务文件。'
exec 9>/run/lock/wgmaint-short-join.lock
flock -n 9 || die '正在安装短命令入口，请稍后重试。'

unit=$(systemctl show -p FragmentPath --value "$service")
mapfile -t launchers < <(sed -n 's/^ExecStart=\(.*\/gunicorn .* \)registry:application$/\1--threads 4 registry_windows:application/p' "$unit")
(( ${#launchers[@]} == 1 )) || die '登记服务启动配置与预期不符，升级已停止。'

work=$(mktemp -d)
changed=false
files=("$module" "$bootstrap" "$dropin" "$firewall" "$launcher")
rollback() {
    local status=$? i
    trap - EXIT
    if (( status != 0 )) && $changed; then
        printf 'Windows 接入入口安装失败，正在恢复原来的登记服务。\n' >&2
        for i in "${!files[@]}"; do
            if [[ -f $work/old.$i ]]; then
                cp -p -- "$work/old.$i" "${files[i]}" || true
            else
                rm -f -- "${files[i]}" || true
            fi
        done
        /usr/sbin/nft -f "$firewall" || true
        systemctl daemon-reload || true
        systemctl restart "$service" || true
    fi
    rm -rf -- "$work"
    exit "$status"
}
trap rollback EXIT

[[ -f $firewall ]] || die '维护防火墙配置不存在。'
awk '
    /iifname .* oifname .* tcp dport (22|[{] 22, 2222 [}]) ct state [{] new, established [}] accept$/ {
        sub(/tcp dport 22 /, "tcp dport { 22, 2222 } "); inbound++
    }
    /iifname .* oifname .* tcp sport (22|[{] 22, 2222 [}]) ct state established accept$/ {
        sub(/tcp sport 22 /, "tcp sport { 22, 2222 } "); outbound++
    }
    { print }
    END { if (inbound != 1 || outbound != 1) exit 1 }
' "$firewall" >"$work/firewall.nft" || die '维护防火墙规则与预期不符，升级已停止。'
/usr/sbin/nft -c -f "$work/firewall.nft" || die '维护防火墙规则检查失败。'

cat >"$work/registry_windows.py" <<'WGMAINT_WINDOWS_PY'
import base64
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time

from registry import STATE, application as registry_app, config, db_connect, digest

if Path(__file__).with_name("registry_download.py").is_file():
    from registry_download import application as registry_app

MARKER = b"WGMAINT_JOIN_DATA_PLACEHOLDER"
TEMPLATE = Path(__file__).with_name("customer-join-windows.ps1").read_bytes()
PACKAGE_NAME = "wireguard-amd64.msi"
PACKAGE_HASH = "7bfed60ad61b785c914b38b61555a975488e1d3ec472dbfb2fcdf498fca75242"
PACKAGE_SIZE = 3293184
PACKAGE_CACHE = STATE / "db" / PACKAGE_NAME
LEGACY_PACKAGE = Path(__file__).with_name(PACKAGE_NAME)
if TEMPLATE.count(MARKER) != 1:
    raise RuntimeError("invalid Windows bootstrap template")


BOOTSTRAP = Path(__file__).with_name("windows-bootstrap.ps1").read_bytes()
CERTIFICATE = subprocess.check_output(
    ["/usr/bin/openssl", "x509", "-in", str(STATE / "join.crt"), "-outform", "DER"], timeout=3,
)
CERTIFICATE_HASH = base64.b64encode(hashlib.sha256(CERTIFICATE).digest())


def origin():
    return "https://" + config()["endpoint"].rsplit(":", 1)[0] + ":8443"


def bootstrap(environ, start_response):
    method = environ["REQUEST_METHOD"]
    if method not in ("HEAD", "GET"):
        return response(start_response, "405 Method Not Allowed")
    body = BOOTSTRAP.replace(b"WGMAINT_BOOTSTRAP_ORIGIN", origin().encode("ascii"))
    body = body.replace(b"WGMAINT_BOOTSTRAP_CERTIFICATE", CERTIFICATE_HASH)
    size = len(body)
    headers = [("Content-Type", "text/plain; charset=us-ascii"), ("Accept-Ranges", "bytes"),
               ("Cache-Control", "no-store"), ("ETag", '"' + hashlib.sha256(body).hexdigest() + '"')]
    status = "200 OK"
    if method == "GET" and environ.get("HTTP_RANGE"):
        match = re.fullmatch(r"bytes=(\d{1,10})-(\d{0,10})", environ["HTTP_RANGE"])
        if not match:
            return response(start_response, "400 Bad Request")
        first = int(match[1])
        last = min(int(match[2]), size - 1) if match[2] else size - 1
        if first > last:
            start_response("416 Range Not Satisfiable", [("Content-Range", f"bytes */{size}"), ("Content-Length", "0")])
            return [b""]
        status = "206 Partial Content"
        headers.append(("Content-Range", f"bytes {first}-{last}/{size}"))
        body = body[first:last + 1]
    headers.append(("Content-Length", str(len(body))))
    start_response(status, headers)
    return [b"" if method == "HEAD" else body]


def urlsafe(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def enrollment_token(code):
    return urlsafe(hashlib.sha256(b"wgmaint-windows-enroll:" + code.encode("ascii")).digest())


def response(start_response, status, body=b"", content_type="text/plain; charset=utf-8"):
    start_response(status, [
        ("Content-Type", content_type), ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
    ])
    return [body]


def register_code(environ, start_response):
    length = int(environ.get("CONTENT_LENGTH") or 0)
    if not 0 < length <= 4096:
        return response(start_response, "400 Bad Request")
    payload = json.loads(environ["wsgi.input"].read(length))
    if not isinstance(payload, dict):
        return response(start_response, "400 Bad Request")
    token, key = payload.get("token"), payload.get("ssh_public_key")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
        return response(start_response, "403 Forbidden")
    if not isinstance(key, str) or not re.fullmatch(
        r"(?:ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa) [A-Za-z0-9+/=]{16,3500}", key
    ):
        return response(start_response, "400 Bad Request")
    code = urlsafe(hashlib.sha256(b"wgmaint-windows-code:" + token.encode("ascii")).digest()[:16])
    binding = digest(enrollment_token(code))
    with closing(db_connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT expires, public_key FROM invitations WHERE digest = ?", (digest(token),)).fetchone()
        if not row or row[0] <= time.time() or row[1] is not None:
            return response(start_response, "403 Forbidden")
        db.execute("""
            CREATE TABLE IF NOT EXISTS windows_codes (
                digest TEXT PRIMARY KEY REFERENCES invitations(digest) ON DELETE CASCADE,
                ssh_public_key TEXT NOT NULL
            )
        """)
        existing = db.execute("SELECT ssh_public_key FROM windows_codes WHERE digest = ?", (binding,)).fetchone()
        if existing and existing[0] != key:
            return response(start_response, "409 Conflict")
        if not existing:
            db.execute("INSERT INTO invitations (digest, expires) VALUES (?, ?)", (binding, row[0]))
            db.execute("INSERT INTO windows_codes VALUES (?, ?)", (binding, key))
    return response(start_response, "200 OK", code.encode("ascii"))


def available_package():
    if PACKAGE_CACHE.is_file():
        return PACKAGE_CACHE
    if LEGACY_PACKAGE.is_file():
        return LEGACY_PACKAGE
    return None


def upload_package(environ, start_response):
    auth = re.fullmatch(r"Bearer ([A-Za-z0-9_-]{43})", environ.get("HTTP_AUTHORIZATION", ""))
    if not auth:
        return response(start_response, "403 Forbidden")
    with closing(db_connect()) as db:
        row = db.execute(
            "SELECT expires, public_key FROM invitations WHERE digest = ?", (digest(auth[1]),)
        ).fetchone()
    if not row or row[0] <= time.time() or row[1] is not None:
        return response(start_response, "403 Forbidden")
    if int(environ.get("CONTENT_LENGTH") or 0) != PACKAGE_SIZE:
        return response(start_response, "400 Bad Request")
    fd, temporary = tempfile.mkstemp(dir=PACKAGE_CACHE.parent, prefix=".wireguard-")
    try:
        checksum = hashlib.sha256()
        remaining = PACKAGE_SIZE
        with os.fdopen(fd, "wb") as output:
            while remaining:
                chunk = environ["wsgi.input"].read(min(65536, remaining))
                if not chunk:
                    return response(start_response, "400 Bad Request")
                checksum.update(chunk)
                output.write(chunk)
                remaining -= len(chunk)
        if checksum.hexdigest() != PACKAGE_HASH:
            return response(start_response, "400 Bad Request")
        os.replace(temporary, PACKAGE_CACHE)
        return response(start_response, "200 OK")
    finally:
        Path(temporary).unlink(missing_ok=True)


def download(code, package, environ, start_response):
    token = enrollment_token(code)
    with closing(db_connect()) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'windows_codes'").fetchone():
            return response(start_response, "403 Forbidden")
        row = db.execute("""
            SELECT i.expires, w.ssh_public_key
            FROM windows_codes w JOIN invitations i USING (digest) WHERE w.digest = ?
        """, (digest(token),)).fetchone()
    if not row or row[0] <= time.time():
        return response(start_response, "403 Forbidden")
    if package:
        path = available_package()
        if path is None:
            return response(start_response, "503 Service Unavailable")
        handle = path.open("rb")
        start_response("200 OK", [
            ("Content-Type", "application/octet-stream"),
            ("Content-Length", str(path.stat().st_size)),
            ("Cache-Control", "no-store"),
        ])
        return environ["wsgi.file_wrapper"](handle) if "wsgi.file_wrapper" in environ else FileChunks(handle)
    data = config()
    data.update(token=token, code=code, ssh_public_key=row[1])
    payload = base64.b64encode(json.dumps(data, sort_keys=True).encode("ascii"))
    return response(start_response, "200 OK", TEMPLATE.replace(MARKER, payload))


class FileChunks:
    def __init__(self, handle):
        self.handle = handle

    def __iter__(self):
        return iter(lambda: self.handle.read(65536), b"")

    def close(self):
        self.handle.close()


def application(environ, start_response):
    path, method = environ["PATH_INFO"], environ["REQUEST_METHOD"]
    try:
        if path == "/b":
            return bootstrap(environ, start_response)
        if path == "/v1/windows-package":
            if method == "HEAD":
                return response(start_response, "200 OK" if available_package() else "204 No Content")
            if method == "POST":
                return upload_package(environ, start_response)
            return response(start_response, "405 Method Not Allowed")
        if path == "/v1/windows-code":
            if method == "HEAD":
                return response(start_response, "200 OK")
            if method == "POST":
                return register_code(environ, start_response)
            return response(start_response, "405 Method Not Allowed")
        if path.startswith("/w/"):
            match = re.fullmatch(r"/w/([A-Za-z0-9_-]{22})(?:/(wg))?", path)
            if not match:
                return response(start_response, "404 Not Found")
            if method != "GET":
                return response(start_response, "405 Method Not Allowed")
            return download(*match.groups(), environ, start_response)
    except (ValueError, UnicodeError):
        return response(start_response, "400 Bad Request")
    except (OSError, sqlite3.Error):
        return response(start_response, "503 Service Unavailable")
    return registry_app(environ, start_response)
WGMAINT_WINDOWS_PY

cat >"$work/customer-join-windows.ps1" <<'WGMAINT_WINDOWS_PS'
$ErrorActionPreference = 'Stop'
$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('WGMAINT_JOIN_DATA_PLACEHOLDER')) | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请在管理员 PowerShell 中执行接入命令。'
}
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or
    [Environment]::OSVersion.Version.Build -lt 17763 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw '需要 x64 Windows 10 1809 / Windows Server 2019 或更新版本的 64 位 Windows PowerShell。'
}

$root = Join-Path $env:ProgramData 'Wgmaint'
$tunnel = 'wgmaint-customer'
$tunnelService = 'WireGuardTunnel$' + $tunnel
$account = 'wgmaint-ssh'
$taskName = 'Wgmaint OpenSSH'
$firewall = 'Wgmaint-SSH'
$port = 2222
$sshDirectory = Join-Path $env:windir 'System32\OpenSSH'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Native($File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "执行失败 ($LASTEXITCODE) $(Split-Path -Leaf $File)" }
}

function Write-Atomic($Path, $Text) {
    $temporary = "$Path.new"
    [IO.File]::WriteAllText($temporary, $Text, $utf8)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $null) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Protect-Directory($Path) {
    if (!(Test-Path -LiteralPath $Path)) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($id in 'S-1-5-18', 'S-1-5-32-544') {
            $sid = New-Object Security.Principal.SecurityIdentifier($id)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
            )
            $acl.AddAccessRule($rule)
        }
        [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
    }
    $directory = Get-Item -LiteralPath $Path -Force
    if (!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '维护目录不是普通目录。'
    }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $sids = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    if (!$acl.AreAccessRulesProtected -or $owner -notin @('S-1-5-18', 'S-1-5-32-544') -or
        @($sids | Where-Object { $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') }).Count) {
        throw '维护目录权限异常，已停止接入。'
    }
}

function Wait-LocalSsh($Address) {
    foreach ($attempt in 1..20) {
        $listener = Get-NetTCPConnection -State Listen -LocalAddress $Address -LocalPort $port -ErrorAction SilentlyContinue
        if ($listener) {
            $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($process -and $process.Path -eq $sshd) { return }
        }
        Start-Sleep -Seconds 1
    }
    throw '隧道 SSH 未开始监听。请查看任务 Wgmaint OpenSSH 和维护目录里的 sshd.log。'
}

$mutex = New-Object Threading.Mutex($false, 'Global\WgmaintCustomerSetup')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw '另一份接入脚本正在运行。' }
    Protect-Directory $root

    Write-Host '[1/4] 安装 WireGuard 和 OpenSSH'
    $wg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    $wireguard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    if (!(Test-Path $wg) -or !(Test-Path $wireguard)) {
        $msi = Join-Path $root 'wireguard.msi'
        try {
            $wgmaintHttp.GetPackage("/w/$($settings.code)/wg", $msi)
            if ((Get-FileHash -Algorithm SHA256 $msi).Hash -ne
                '7bfed60ad61b785c914b38b61555a975488e1d3ec472dbfb2fcdf498fca75242') {
                throw 'WireGuard 安装包校验失败。'
            }
            $installer = Start-Process -FilePath msiexec.exe -ArgumentList @(
                '/i', ('"' + $msi + '"'), '/qn', '/norestart', 'DO_NOT_LAUNCH=1'
            ) -Wait -PassThru
            if ($installer.ExitCode -eq 3010) { throw 'WireGuard 安装需要重启。重启后请用新接入命令重试。' }
            if ($installer.ExitCode -ne 0) { throw "WireGuard 安装失败 ($($installer.ExitCode))。" }
        } finally {
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        }
    }
    $sshd = Join-Path $sshDirectory 'sshd.exe'
    if (!(Test-Path $sshd)) {
        $defaultRule = 'OpenSSH-Server-In-TCP'
        $hadRule = Get-NetFirewallRule -Name $defaultRule -ErrorAction SilentlyContinue
        try {
            $feature = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
            if ($feature.RestartNeeded) { throw 'OpenSSH 安装需要重启。重启后请用新接入命令重试。' }
        } finally {
            if (!$hadRule) {
                Get-NetFirewallRule -Name $defaultRule -ErrorAction SilentlyContinue | Disable-NetFirewallRule
            }
        }
        if (!(Test-Path $sshd)) { throw 'Windows OpenSSH 服务器安装失败。' }
    }

    $generator = Join-Path $sshDirectory 'ssh-keygen.exe'
    if (!(Test-Path $generator)) {
        $feature = Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0'
        if ($feature.RestartNeeded) { throw 'OpenSSH 安装需要重启。重启后请用新接入命令重试。' }
        if (!(Test-Path $generator)) { throw '找不到 OpenSSH 主机密钥生成工具。' }
    }

    Write-Host '[2/4] 登记并启动 WireGuard 隧道'
    $secretFile = Join-Path $root 'wireguard.key'
    if (!(Test-Path $secretFile)) {
        $newKey = (Invoke-Native $wg @('genkey')).Trim()
        if ($newKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'WireGuard 私钥生成失败。' }
        Write-Atomic $secretFile ($newKey + "`n")
    }
    $privateKey = [IO.File]::ReadAllText($secretFile).Trim()
    $publicKey = ($privateKey | & $wg pubkey).Trim()
    if ($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^[A-Za-z0-9+/]{43}=$') {
        throw 'WireGuard 公钥生成失败。'
    }
    $request = @{ token = $settings.token; public_key = $publicKey } | ConvertTo-Json -Compress
    $result = $wgmaintHttp.PostJson('/v1/enroll', $request)
    $peer = $result | ConvertFrom-Json
    if ($peer.address -notmatch '^\d{1,3}(\.\d{1,3}){3}/32$' -or
        $peer.admin_ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        $peer.admin_ip -ne $settings.admin_ip -or $peer.endpoint -ne $settings.endpoint -or
        $peer.server_public_key -ne $settings.server_public_key) { throw 'VPS 返回了不匹配的隧道配置。' }
    $address = $peer.address.Split('/')[0]
    $config = Join-Path $root "$tunnel.conf"
    $configText = @"
[Interface]
PrivateKey = $privateKey
Address = $($peer.address)

[Peer]
PublicKey = $($peer.server_public_key)
AllowedIPs = $($peer.admin_ip)/32
Endpoint = $($peer.endpoint)
PersistentKeepalive = 25
"@
    $existingTunnel = Get-Service -Name $tunnelService -ErrorAction SilentlyContinue
    if ($existingTunnel -and !(Test-Path $config)) { throw '发现同名 WireGuard 隧道，已停止接入。' }
    if (!$existingTunnel -or [IO.File]::ReadAllText($config) -ne $configText) {
        if ($existingTunnel) { Invoke-Native $wireguard @('/uninstalltunnelservice', $tunnel) }
        Write-Atomic $config $configText
        Invoke-Native $wireguard @('/installtunnelservice', $config)
    }
    Start-Service -Name $tunnelService
    $handshake = $false
    foreach ($attempt in 1..45) {
        $handshakes = & $wg show $tunnel latest-handshakes 2>$null
        if ($LASTEXITCODE -eq 0 -and $handshakes -match '\s[1-9]\d*\s*$' -and
            (Get-NetIPAddress -IPAddress $address -ErrorAction SilentlyContinue)) {
            $handshake = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (!$handshake) { throw 'WireGuard 未完成握手。请检查客户机出站网络和 VPS 的 UDP 51820。' }

    Write-Host '[3/4] 配置仅在维护隧道监听的 SSH'
    $user = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
    $accountFile = Join-Path $root 'account.sid'
    if ($user -and (!(Test-Path $accountFile) -or [IO.File]::ReadAllText($accountFile) -ne $user.SID.Value)) {
        throw '已存在同名的非托管 Windows 账号。'
    }
    if (!$user) {
        $random = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N') + 'Aa1!'
        $password = ConvertTo-SecureString $random -AsPlainText -Force
        $user = New-LocalUser -Name $account -Password $password -PasswordNeverExpires -UserMayNotChangePassword
        Write-Atomic $accountFile $user.SID.Value
    }
    $admins = Get-LocalGroupMember -SID 'S-1-5-32-544'
    if ($admins.SID -contains $user.SID) { throw '维护账号拥有管理员权限，已停止接入。' }
    $users = Get-LocalGroupMember -SID 'S-1-5-32-545'
    if ($users.SID -notcontains $user.SID) { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user }

    $hostKey = Join-Path $root 'ssh_host_ed25519_key'
    if (!(Test-Path $hostKey)) {
        $keygenArgs = '-q -t ed25519 -N "" -f "' + $hostKey + '"'
        $generated = Start-Process -FilePath $generator -ArgumentList $keygenArgs -Wait -NoNewWindow -PassThru
        if ($generated.ExitCode -ne 0) { throw 'SSH 主机密钥生成失败。' }
    }
    $authorized = Join-Path $root 'authorized_keys'
    Write-Atomic $authorized ('from="' + $peer.admin_ip + '",restrict,pty ' + $settings.ssh_public_key + "`n")
    Invoke-Native icacls.exe @($authorized, '/grant:r', ('*' + $user.SID.Value + ':R')) | Out-Null
    $sshConfig = Join-Path $root 'sshd_config'
    $hostPath = $hostKey.Replace('\', '/')
    $authorizedPath = $authorized.Replace('\', '/')
    Write-Atomic $sshConfig @"
Port $port
AddressFamily inet
ListenAddress $address
HostKey "$hostPath"
AuthorizedKeysFile "$authorizedPath"
AllowUsers $account@$($peer.admin_ip)
AuthenticationMethods publickey
PasswordAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
"@
    Invoke-Native $sshd @('-t', '-f', $sshConfig)
    $oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($oldTask) { Stop-ScheduledTask -TaskName $taskName }
    $oldRule = Get-NetFirewallRule -Name $firewall -ErrorAction SilentlyContinue
    if ($oldRule) { $oldRule | Remove-NetFirewallRule }
    New-NetFirewallRule -Name $firewall -DisplayName 'Wgmaint SSH tunnel' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $port -LocalAddress $address -RemoteAddress $peer.admin_ip -Program $sshd | Out-Null
    $logFile = Join-Path $root 'sshd.log'
    $action = New-ScheduledTaskAction -Execute $sshd -Argument ('-D -f "' + $sshConfig + '" -E "' + $logFile + '"')
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $taskSettings `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Wait-LocalSsh $address

    Write-Host '[4/4] 接入成功。WireGuard 已握手，SSH 已监听。' -ForegroundColor Green
    Write-Host "在已接入 WireGuard 的 Mac 上运行 ssh -p $port $account@$address"
    Invoke-Native $generator @('-lf', "$hostKey.pub")
} catch {
    Write-Host "接入失败。$($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
WGMAINT_WINDOWS_PS

cat >"$work/windows-bootstrap.ps1" <<'WGMAINT_WINDOWS_BOOT'
if ($t -cnotmatch '^[A-Za-z0-9_-]{22}$') { throw 'Invalid onboarding code.' }
$origin = 'WGMAINT_BOOTSTRAP_ORIGIN'
$certificateHash = 'WGMAINT_BOOTSTRAP_CERTIFICATE'
if (-not ('WgmaintHttps' -as [type])) {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;

public sealed class WgmaintHttps
{
    private readonly Uri origin;
    private readonly string certificateHash;

    public WgmaintHttps(string origin, string certificateHash)
    {
        this.origin = new Uri(origin);
        this.certificateHash = certificateHash;
    }

    private byte[] Request(string path, string json, int limit)
    {
        if (!path.StartsWith("/", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal))
            throw new ArgumentException("Invalid relative path.", "path");

        var request = (HttpWebRequest)WebRequest.Create(new Uri(origin, path));
        request.AllowAutoRedirect = false;
        request.Proxy = null;
        request.Timeout = 25000;
        request.ReadWriteTimeout = 25000;
        request.ServerCertificateValidationCallback = (sender, certificate, chain, errors) =>
        {
            if (certificate == null) return false;
            using (var sha = SHA256.Create())
                return Convert.ToBase64String(sha.ComputeHash(certificate.GetRawCertData())) == certificateHash;
        };
        if (json != null)
        {
            byte[] data = Encoding.UTF8.GetBytes(json);
            request.Method = "POST";
            request.ContentType = "application/json";
            request.ContentLength = data.Length;
            using (Stream body = request.GetRequestStream()) body.Write(data, 0, data.Length);
        }
        using (var response = (HttpWebResponse)request.GetResponse())
        {
            if (response.StatusCode != HttpStatusCode.OK || response.ContentLength < 1 ||
                response.ContentLength > limit)
                throw new IOException("Invalid HTTPS response.");
            using (var input = response.GetResponseStream())
            using (var output = new MemoryStream((int)response.ContentLength))
            {
                byte[] buffer = new byte[65536];
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                {
                    if (output.Length + read > limit) throw new IOException("Response too large.");
                    output.Write(buffer, 0, read);
                }
                if (output.Length != response.ContentLength) throw new IOException("Incomplete HTTPS response.");
                return output.ToArray();
            }
        }
    }

    public string GetScript(string path) { return Encoding.UTF8.GetString(Request(path, null, 65536)); }
    public string PostJson(string path, string json) { return Encoding.UTF8.GetString(Request(path, json, 65536)); }
    public void GetPackage(string path, string filename) { File.WriteAllBytes(filename, Request(path, null, 3293184)); }
}
'@
}
$wgmaintHttp = [WgmaintHttps]::new($origin, $certificateHash)
& ([scriptblock]::Create($wgmaintHttp.GetScript("/w/$t")))
WGMAINT_WINDOWS_BOOT

python3 - "$work/registry_windows.py" <<'WGMAINT_CHECK_PY'
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
put "$work/registry_windows.py" "$module"
put "$work/customer-join-windows.ps1" "$bootstrap"
put "$work/windows-bootstrap.ps1" "$launcher"
put "$work/short-join.conf" "$dropin"
install -m 0600 "$work/firewall.nft" "$firewall.wgmaint-new"
mv -f -- "$firewall.wgmaint-new" "$firewall"
/usr/sbin/nft -f "$firewall"
systemctl daemon-reload
systemctl restart "$service"

for attempt in {1..12}; do
    status=$(curl -qsSI --noproxy '*' --max-time 2 --cacert "$state/join.crt" \
        --connect-to "$endpoint:8443:127.0.0.1:8443" --output /dev/null --write-out '%{http_code}' \
        "https://$endpoint:8443/v1/windows-code" 2>/dev/null) || status=000
    if [[ $status == 200 ]]; then
        printf 'Windows 接入入口已启用。回 Mac 点「新客户接入」，把短命令贴到客户机的管理员 PowerShell。\n'
        exit 0
    fi
    sleep 1
done
die '本机检查未通过。'
WGMAINT_WINDOWS_SETUP

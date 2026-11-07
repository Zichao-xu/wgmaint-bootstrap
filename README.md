# wgmaint-bootstrap

一键远程维护工具：维护用的公网 Linux VPS + Windows / macOS 客户机。

## 两条命令

1. 部署维护 VPS（Debian/Ubuntu，在 VPS 上粘贴；会覆盖旧部署并重新签发登记码）：

    curl -fsSL -H 'Accept: application/vnd.github.raw+json' 'https://api.github.com/repos/Zichao-xu/wgmaint-bootstrap/contents/vps-deploy.sh?ref=main' | WGMAINT_APT_REGION=cn bash

   部署结束会打印一行 WM2: 开头的登记码，回 Mac 第一次使用「新客户接入」时粘贴一次。

2. 新客户接入（Mac 快捷指令调用的就是这条）：

    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    exec /bin/bash "/Users/adams/Documents/Codex/2026-11-07/new-chat-2/outputs/new-customer.sh" --vps admin@120.79.191.224 --copy

## 流程

1. 客户机粘贴生成的短命令（Windows 直接粘贴到 Win+R 或管理员 PowerShell）。
2. 客户机自动装 WireGuard、登记隧道、装受限 SSH。
3. 回 Mac 执行 ssh -p 2222 wgmaint-ssh@<隧道IP>。

## 端口

- UDP 51820：WireGuard
- TCP 8443：登记服务（HTTP）

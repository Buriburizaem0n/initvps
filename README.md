# Ubuntu VPS Initialization & Security Script

[![OS](https://img.shields.io/badge/OS-Ubuntu_20.04%2F22.04%2F24.04-orange?style=flat-square&logo=ubuntu)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

这是一个专为 **Ubuntu LTS (20.04 / 22.04 / 24.04)** 设计的服务器初始化与安全加固脚本。
它旨在通过一次交互式运行，完成新机器从“裸机”到“生产就绪”的安全配置，特别针对 Ubuntu 24.04 的 SSH 机制进行了适配。

## 🚀 核心功能 (Features)

- **🔐 账户安全**:
  - 创建新的 sudo 管理员用户。
  - **强制双重校验**设置密码。
  - 配置 `/etc/sudoers.d` 实现 sudo 免密。
- **🔑 SSH 加固**:
  - **强制密钥登录**: 支持导入已有公钥或**自动生成 Ed25519 密钥对**。
  - **修改 SSH 端口**: 自动修改配置文件并适配防火墙。
  - **封死旧入口**: 禁用 Root 登录，禁用密码认证。
  - **Ubuntu 24.04 修复**: 自动处理 `ssh.socket` 问题，确保自定义端口生效。
- **🛡️ 网络防御**:
  - **UFW 防火墙**: 默认启用，仅放行自定义 SSH 端口、80、443。
  - **BBR 加速**: 自动开启 TCP BBR 拥塞控制。

## ⚡️ 一键安装 (Quick Start)

使用 `root` 用户登录服务器，运行以下命令即可：

> **注意**: 请确保替换命令中的 URL 为你实际的仓库地址。

```bash
bash <(curl -sL https://raw.githubusercontent.com/Buriburizaem0n/initvps/Ubuntu-24.04/init.sh)

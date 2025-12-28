#!/bin/sh

# =======================================================================
# 脚本名称: Alpine Linux 安全初始化脚本 (Alpine 3.19+)
# 功能: 依赖安装 / 创建用户 / Sudo配置 / SSH Key / 改端口 / UFW / BBR
# =======================================================================

# 定义颜色 (Alpine默认sh可能不支持复杂转义，尽量保持简单)
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 1. 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本 (doas sh script.sh 或 sudo sh script.sh)${NC}"
    exit 1
fi

clear
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Alpine Linux 全自动安全初始化脚本        ${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${RED}警告：本脚本将禁用 Root 登录和密码认证！${NC}"
echo ""

# ====================================================
# 0. 环境准备 (Alpine 特有)
# ====================================================
echo -e "${YELLOW}>>> [0/7] 正在配置 Alpine 环境与依赖...${NC}"

# 启用 Community 仓库 (UFW 和其他工具通常在这里)
sed -i 's/^#.*community/http:\/\/dl-cdn.alpinelinux.org\/alpine\/v3.19\/community/' /etc/apk/repositories
# 如果上面命令没生效（因为版本号可能是 edge 或其他），尝试通用匹配
sed -i 's/^#\(.*community\)/\1/' /etc/apk/repositories

apk update

# 安装基础工具
# bash: 为了脚本交互方便
# sudo: 权限管理
# shadow: 提供了 useradd, usermod, chpasswd 等标准命令
# ufw: 防火墙
# openssh: 确保 ssh 服务存在
echo -e "${CYAN}安装依赖包 (bash, sudo, shadow, ufw, openssh)...${NC}"
apk add bash sudo shadow ufw openssh curl nano

# ====================================================
# 1. 创建用户与 sudo 配置
# ====================================================
echo -e "\n${YELLOW}>>> [1/7] 创建新管理员用户${NC}"

# 切换到 bash 逻辑来处理输入，或者使用 sh 兼容写法
# 这里使用 read 循环
while true; do
    printf "请输入新用户名: "
    read NEW_USER
    if [ -z "$NEW_USER" ]; then
        echo "用户名不能为空"
    elif id "$NEW_USER" >/dev/null 2>&1; then
        echo -e "${RED}用户 $NEW_USER 已存在，请换一个名字。${NC}"
    else
        break
    fi
done

# 密码设置
while true; do
    echo -e "${CYAN}请设置该用户的系统密码 (仅用于 sudo 提权):${NC}"
    # sh 不支持 read -s，使用 stty -echo
    stty -echo
    printf "输入密码: "
    read PASS1
    echo ""
    printf "确认密码: "
    read PASS2
    echo ""
    stty echo
    
    if [ -z "$PASS1" ]; then
        echo -e "${RED}密码不能为空。${NC}"
    elif [ "$PASS1" != "$PASS2" ]; then
        echo -e "${RED}两次输入的密码不一致。${NC}"
    else
        NEW_PASS="$PASS1"
        break
    fi
done

# 创建用户
# Alpine 默认 shell 是 ash，这里指定为 /bin/bash
useradd -m -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$NEW_PASS" | chpasswd

# Alpine 中管理员组通常是 wheel
usermod -aG wheel "$NEW_USER"

# 配置 sudo 免密
echo -e "${CYAN}配置 sudo 免密...${NC}"
SUDO_FILE="/etc/sudoers.d/$NEW_USER"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDO_FILE"
chmod 0440 "$SUDO_FILE"

# ====================================================
# 2. SSH 密钥配置
# ====================================================
echo -e "\n${YELLOW}>>> [2/7] 配置 SSH 密钥认证${NC}"
USER_SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$USER_SSH_DIR"

echo "请选择 SSH 公钥模式:"
echo " [1] 我有公钥 (推荐)"
echo " [2] 我没有，请帮我生成新密钥"
printf "请输入选项 [1/2]: "
read KEY_OPTION

if [ "$KEY_OPTION" = "1" ]; then
    echo ""
    echo "请粘贴你的 SSH 公钥:"
    read USER_PUB_KEY
    if [ -z "$USER_PUB_KEY" ]; then
        echo -e "${RED}公钥不能为空！退出。${NC}"
        exit 1
    fi
    echo "$USER_PUB_KEY" > "$USER_SSH_DIR/authorized_keys"
    echo -e "${GREEN}公钥已导入。${NC}"

else
    echo -e "${CYAN}正在生成 Ed25519 密钥对...${NC}"
    ssh-keygen -t ed25519 -f "$USER_SSH_DIR/id_ed25519" -N "" -C "$NEW_USER@alpine" -q
    mv "$USER_SSH_DIR/id_ed25519.pub" "$USER_SSH_DIR/authorized_keys"
    
    echo -e "\n${RED}!!! 请保存私钥内容 (一次性显示) !!!${NC}"
    echo "--------------------------------------------------------"
    cat "$USER_SSH_DIR/id_ed25519"
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}请保存并在本地设置权限 (chmod 600 keyfile)${NC}"
    printf "按回车继续..."
    read DUMMY
    rm -f "$USER_SSH_DIR/id_ed25519"
fi

chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$USER_SSH_DIR/authorized_keys"

# ====================================================
# 3. SSH 安全配置
# ====================================================
echo -e "\n${YELLOW}>>> [3/7] 加固 SSH 服务${NC}"

while true; do
    printf "请输入新的 SSH 端口号 (1024-65535): "
    read SSH_PORT
    # 简单的数字检查
    case $SSH_PORT in
        ''|*[!0-9]*) echo "请输入有效的数字";;
        *) if [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then break; fi;;
    esac
done

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"

# 使用 sed 修改配置
sed -i "s/^#Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
sed -i "s/^Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
# 如果文件中根本没有 Port 行，追加一行
if ! grep -q "^Port" "$SSHD_CONFIG"; then echo "Port $SSH_PORT" >> "$SSHD_CONFIG"; fi

sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"

sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

echo -e "${GREEN}SSH 配置已更新。${NC}"

# ====================================================
# 4. 防火墙配置 (UFW via OpenRC)
# ====================================================
echo -e "\n${YELLOW}>>> [4/7] 配置 UFW 防火墙${NC}"

# 确保 ip6tables 存在 (UFW 在 Alpine 有时需要)
apk add ip6tables >/dev/null 2>&1

# 重置 UFW
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

ufw allow "$SSH_PORT/tcp" comment "SSH Port"
echo -e "已放行端口: $SSH_PORT"
ufw allow 80/tcp comment "Http Port"
ufw allow 443/tcp comment "Https Port"

# 启用 UFW
# Alpine 中需要先启用服务自启
rc-update add ufw default
echo "y" | ufw enable
echo -e "${GREEN}防火墙已启用。${NC}"

# ====================================================
# 5. 开启 BBR
# ====================================================
echo -e "\n${YELLOW}>>> [5/7] 开启 BBR${NC}"

# Alpine 加载模块的方式不同
if ! grep -q "tcp_bbr" /etc/modules; then
    echo "tcp_bbr" >> /etc/modules
    modprobe tcp_bbr
fi

if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null
    echo -e "${GREEN}BBR 已开启。${NC}"
else
    echo -e "${CYAN}BBR 已配置，跳过。${NC}"
fi

# ====================================================
# 6. 系统更新与清理
# ====================================================
echo -e "\n${YELLOW}>>> [6/7] 系统更新${NC}"
apk upgrade
# 清理缓存
rm -rf /var/cache/apk/*

# ====================================================
# 7. 重启服务 (OpenRC)
# ====================================================
echo -e "\n${YELLOW}>>> [7/7] 重启 SSH 服务${NC}"

# 添加 SSH 到默认运行级别 (防止重启后没 SSH)
rc-update add sshd default >/dev/null 2>&1

# 重启 SSHD
rc-service sshd restart

if rc-service sshd status | grep -q "started"; then
    echo -e "${GREEN}SSH 服务运行正常。${NC}"
else
    echo -e "${RED}⚠️ SSH 服务重启似乎有问题，请检查 'rc-service sshd status'${NC}"
fi

# ====================================================
# 完成
# ====================================================
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}       🎉 Alpine 初始化完成!       ${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "用户: ${YELLOW}$NEW_USER${NC}"
echo -e "端口: ${YELLOW}$SSH_PORT${NC}"
echo ""
echo -e "${RED}=== 验证步骤 ===${NC}"
echo -e "1. 保持当前连接不关闭。"
echo -e "2. 新开窗口测试: ssh -p $SSH_PORT $NEW_USER@<IP>"
echo -e "3. 验证 sudo 权限。"

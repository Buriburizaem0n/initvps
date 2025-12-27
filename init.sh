#!/bin/bash

# =======================================================================
# 脚本名称: Ubuntu 安全初始化脚本 (Ubuntu 20.04/22.04/24.04 兼容版)
# 功能: 创建用户(双重密码校验) / Sudo免密 / SSH Key / 改SSH端口 / 禁Root和密码 / UFW / BBR
# =======================================================================

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误：请使用 root 权限运行此脚本 (sudo bash init.sh)${NC}"
    exit 1
fi

clear
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}    Ubuntu 全自动安全初始化脚本 (Hardened)  ${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${RED}警告：本脚本将禁用 Root 登录和密码认证！${NC}"
echo -e "${RED}请确保你能够妥善保管 SSH 密钥，否则将失去服务器访问权限。${NC}"
echo ""

# ====================================================
# 1. 创建用户与 sudo 配置 (新增：双重密码校验)
# ====================================================
echo -e "${YELLOW}>>> [1/6] 创建新管理员用户${NC}"

# 获取用户名
while true; do
    read -p "请输入新用户名: " NEW_USER
    if [[ -z "$NEW_USER" ]]; then
        echo "用户名不能为空"
    elif id "$NEW_USER" &>/dev/null; then
        echo -e "${RED}用户 $NEW_USER 已存在，请换一个名字。${NC}"
    else
        break
    fi
done

# 获取密码 (双重校验循环)
while true; do
    echo -e "${CYAN}请设置该用户的系统密码 (仅用于 sudo 提权/本地登录):${NC}"
    read -s -p "输入密码: " PASS1
    echo ""
    read -s -p "确认密码: " PASS2
    echo ""
    
    if [[ -z "$PASS1" ]]; then
        echo -e "${RED}密码不能为空，请重试。${NC}"
    elif [[ "$PASS1" != "$PASS2" ]]; then
        echo -e "${RED}两次输入的密码不一致，请重试。${NC}"
    else
        NEW_PASS="$PASS1"
        echo -e "${GREEN}密码设置成功。${NC}"
        break
    fi
done

# 创建用户并设置密码
useradd -m -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$NEW_PASS" | chpasswd
usermod -aG sudo "$NEW_USER"

# 配置 sudo 免密
echo -e "${CYAN}配置 sudo 免密...${NC}"
SUDO_FILE="/etc/sudoers.d/$NEW_USER"
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" | tee "$SUDO_FILE" > /dev/null
chmod 0440 "$SUDO_FILE"

# ====================================================
# 2. SSH 密钥配置
# ====================================================
echo -e "\n${YELLOW}>>> [2/6] 配置 SSH 密钥认证${NC}"
USER_SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$USER_SSH_DIR"

echo "请选择 SSH 公钥模式:"
echo " [1] 我有公钥 (推荐，直接粘贴 id_rsa.pub 内容)"
echo " [2] 我没有，请帮我生成一对新密钥 (显示私钥并在服务器销毁)"
read -p "请输入选项 [1/2]: " KEY_OPTION

if [ "$KEY_OPTION" == "1" ]; then
    echo ""
    echo "请粘贴你的 SSH 公钥 (以 ssh-rsa 或 ssh-ed25519 开头):"
    read -e USER_PUB_KEY
    if [[ -z "$USER_PUB_KEY" ]]; then
        echo -e "${RED}公钥不能为空！脚本退出以防失联。${NC}"
        exit 1
    fi
    echo "$USER_PUB_KEY" > "$USER_SSH_DIR/authorized_keys"
    echo -e "${GREEN}公钥已导入。${NC}"

else
    echo -e "${CYAN}正在生成 Ed25519 密钥对...${NC}"
    ssh-keygen -t ed25519 -f "$USER_SSH_DIR/id_ed25519" -N "" -C "$NEW_USER@server" -q
    mv "$USER_SSH_DIR/id_ed25519.pub" "$USER_SSH_DIR/authorized_keys"
    
    echo -e "\n${RED}!!! 重要：请立即复制并保存下面的私钥内容 !!!${NC}"
    echo -e "${RED}!!! 你只有这一次机会查看它，丢失将无法登录 !!!${NC}"
    echo "--------------------------------------------------------"
    cat "$USER_SSH_DIR/id_ed25519"
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}请将上方内容保存为本地文件 (例如: myserver.key)${NC}"
    read -p "如果你已保存好私钥，请按回车继续..."
    rm -f "$USER_SSH_DIR/id_ed25519" 
    echo -e "${CYAN}服务器端私钥副本已清理。${NC}"
fi

# 修正 SSH 目录权限
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$USER_SSH_DIR/authorized_keys"

# ====================================================
# 3. SSH 安全配置 (改端口 + 禁密码 + 禁Root)
# ====================================================
echo -e "\n${YELLOW}>>> [3/6] 加固 SSH 服务配置${NC}"

# 获取新端口
while true; do
    read -p "请输入新的 SSH 端口号 (建议 1024-65535): " SSH_PORT
    if [[ "$SSH_PORT" -ge 1024 && "$SSH_PORT" -le 65535 ]]; then
        break
    else
        echo "端口无效，请输入 1024 到 65535 之间的数字。"
    fi
done

SSHD_CONFIG="/etc/ssh/sshd_config"
# 备份配置
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%F_%T)"

# 1. 修改端口
if grep -q "^Port" "$SSHD_CONFIG"; then
    sed -i "s/^Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
elif grep -q "^#Port" "$SSHD_CONFIG"; then
    sed -i "s/^#Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
fi

# 2. 禁止 Root 登录
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
if ! grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi

# 3. 禁止密码认证
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
if ! grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
fi

# 4. 确保公钥认证开启
sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#PubkeyAuthentication/PubkeyAuthentication/' "$SSHD_CONFIG"

echo -e "${GREEN}SSH 配置文件已修改。${NC}"

# ====================================================
# 4. 防火墙配置 (UFW)
# ====================================================
echo -e "\n${YELLOW}>>> [4/6] 配置 UFW 防火墙${NC}"
apt-get update -qq
apt-get install -y ufw -qq > /dev/null

# 重置并设置默认规则
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing

# 开放端口
ufw allow "$SSH_PORT/tcp" comment "SSH Port"
echo -e "已放行自定义 SSH 端口: $SSH_PORT"
ufw allow 80/tcp comment "http port"
ufw allow 443/tcp comment "https port"

# 启用防火墙
echo "y" | ufw enable
echo -e "${GREEN}防火墙已启用。${NC}"

# ====================================================
# 5. 开启 BBR
# ====================================================
echo -e "\n${YELLOW}>>> [5/6] 开启 TCP BBR${NC}"
if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo -e "${CYAN}BBR 配置已存在，跳过。${NC}"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo -e "${GREEN}BBR 已开启。${NC}"
fi

# ====================================================
# 6. 重启服务 (兼容 Ubuntu 24.04 Socket 模式)
# ====================================================
echo -e "\n${YELLOW}>>> [6/6] 重启 SSH 服务以应用更改${NC}"

if systemctl is-active --quiet ssh.socket; then
    echo -e "${CYAN}检测到 Ubuntu 24.04+ Socket 模式，正在切换至 Service 模式...${NC}"
    systemctl stop ssh.socket
    systemctl disable ssh.socket
    systemctl enable ssh.service
    systemctl start ssh.service
else
    echo -e "${CYAN}重启 SSH 服务...${NC}"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
fi

if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
    echo -e "${GREEN}SSH 服务运行正常。${NC}"
else
    echo -e "${RED}⚠️ 警告: SSH 服务似乎启动失败! 请检查 'systemctl status ssh'。${NC}"
fi

# ====================================================
# 完成摘要
# ====================================================
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}       🎉 初始化设置全部完成!       ${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "用户名   : ${YELLOW}$NEW_USER${NC}"
echo -e "SSH 端口 : ${YELLOW}$SSH_PORT${NC}"
echo -e "认证方式 : ${YELLOW}仅密钥 (Root登录已禁, 密码登录已禁)${NC}"
echo ""
echo -e "${RED}=== 🚨 验证步骤 (非常重要) ===${NC}"
echo -e "1. 【不要】关闭当前的 Root 终端窗口！"
echo -e "2. 打开一个新的终端窗口。"
if [ "$KEY_OPTION" == "2" ]; then
    echo -e "3. 连接测试: ssh -i myserver.key -p $SSH_PORT $NEW_USER@<服务器IP>"
else
    echo -e "3. 连接测试: ssh -p $SSH_PORT $NEW_USER@<服务器IP>"
fi
echo -e "4. 验证成功后再关闭当前 Root 连接。"
echo ""

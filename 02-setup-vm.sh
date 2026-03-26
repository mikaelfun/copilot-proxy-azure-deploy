#!/usr/bin/env bash
# ============================================================
#  Copilot Proxy + new-api — VM 环境安装脚本
#  在 Azure VM (Ubuntu 24.04) 上通过 SSH 执行
#  用法: sudo ./02-setup-vm.sh
# ============================================================

set -euo pipefail

# ========== 颜色输出 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

step()    { echo -e "\n${CYAN}▶ $1${NC}"; }
success() { echo -e "  ${GREEN}✔ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
fail()    { echo -e "  ${RED}✘ $1${NC}"; exit 1; }

# ========== 检查权限 ==========
if [[ $EUID -ne 0 ]]; then
    fail "请使用 sudo 运行此脚本"
fi

REAL_USER="${SUDO_USER:-azureuser}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo -e "${MAGENTA}"
echo "═══════════════════════════════════════════════"
echo "  Copilot Proxy + new-api — VM 环境安装"
echo "═══════════════════════════════════════════════"
echo -e "${NC}"

# ========== 1. 系统更新 ==========
step "更新系统软件包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
success "系统更新完成"

# ========== 2. 安装 Docker ==========
step "安装 Docker..."

if command -v docker &>/dev/null; then
    warn "Docker 已安装，跳过"
else
    # 安装依赖
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # 添加 Docker 官方 GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 添加 Docker 仓库
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # 将用户加入 docker 组
    usermod -aG docker "$REAL_USER" || true

    systemctl enable docker
    systemctl start docker
    success "Docker 安装完成"
fi

# ========== 3. 安装 Python3 + venv ==========
step "安装 Python3 及虚拟环境工具..."

apt-get install -y -qq python3 python3-venv python3-pip git
success "Python3 安装完成"

# ========== 4. 安装 Nginx + Certbot ==========
step "安装 Nginx 和 Certbot..."

apt-get install -y -qq nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx
success "Nginx 安装完成"

# ========== 5. 克隆 Copilot Proxy ==========
step "克隆 Copilot Proxy 仓库..."

PROXY_DIR="/opt/copilot-proxy"

if [[ -d "$PROXY_DIR/Copilot_Proxy" ]]; then
    warn "Copilot Proxy 已存在，拉取最新代码..."
    cd "$PROXY_DIR/Copilot_Proxy"
    git pull || warn "git pull 失败，使用现有代码"
else
    mkdir -p "$PROXY_DIR"
    cd "$PROXY_DIR"
    git clone https://github.com/Open-Copilot-Proxy/Copilot_Proxy.git
    success "仓库克隆完成"
fi

# ========== 6. 创建 Python 虚拟环境 ==========
step "创建 Python 虚拟环境并安装依赖..."

VENV_DIR="$PROXY_DIR/venv"

if [[ -d "$VENV_DIR" ]]; then
    warn "虚拟环境已存在，跳过创建"
else
    python3 -m venv "$VENV_DIR"
    success "虚拟环境创建完成"
fi

"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet flask requests
success "Python 依赖安装完成"

# ========== 7. 应用 Copilot Proxy 补丁 ==========
step "应用 Copilot Proxy 代码补丁..."

PATCHER="$REAL_HOME/copilot_proxy_patches.py"

if [[ -f "$PATCHER" ]]; then
    python3 "$PATCHER"
    success "补丁应用完成"
else
    warn "未找到 copilot_proxy_patches.py ($PATCHER)，跳过补丁"
    warn "请手动将补丁脚本上传到 VM 后执行: python3 $PATCHER"
fi

# ========== 8. 部署 new-api Docker 容器 ==========
step "部署 new-api Docker 容器..."

# 创建数据目录
mkdir -p /opt/new-api/data

if docker ps -a --format '{{.Names}}' | grep -q '^new-api$'; then
    warn "new-api 容器已存在"
    if docker ps --format '{{.Names}}' | grep -q '^new-api$'; then
        warn "容器正在运行"
    else
        docker start new-api
        success "已启动现有容器"
    fi
else
    docker run -d \
        --name new-api \
        --restart always \
        -p 3000:3000 \
        -v /opt/new-api/data:/data \
        --add-host=host.docker.internal:host-gateway \
        -e TZ=Asia/Shanghai \
        calciumion/new-api:latest

    success "new-api 容器已启动"
fi

# ========== 9. 创建 systemd 服务 ==========
step "创建 Copilot Proxy systemd 服务..."

cat > /etc/systemd/system/copilot-proxy.service << 'EOF'
[Unit]
Description=Copilot Proxy - GitHub Copilot API Gateway
After=network.target docker.service
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/opt/copilot-proxy/Copilot_Proxy
ExecStart=/opt/copilot-proxy/venv/bin/python main.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable copilot-proxy
success "systemd 服务配置完成"

# ========== 10. 配置 Nginx 默认代理（HTTP） ==========
step "配置 Nginx HTTP 反向代理..."

cat > /etc/nginx/sites-available/new-api << 'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # new-api 反向代理
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
NGINXEOF

# 启用配置
ln -sf /etc/nginx/sites-available/new-api /etc/nginx/sites-enabled/new-api
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
success "Nginx 配置完成"

# ========== 完成 ==========
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✔ 环境安装完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  已部署组件:"
echo -e "    ${GREEN}●${NC} Docker           — 运行中"
echo -e "    ${GREEN}●${NC} new-api          — http://localhost:3000"
echo -e "    ${GREEN}●${NC} Nginx            — http://localhost:80"
echo -e "    ${YELLOW}●${NC} Copilot Proxy    — 需要先完成 OAuth 授权"
echo ""
echo -e "  ${YELLOW}下一步操作:${NC}"
echo -e "    运行 OAuth 授权脚本: ${CYAN}sudo ~/04-authorize-copilot.sh${NC}"
echo ""
echo -e "  ${YELLOW}如需配置 HTTPS:${NC}"
echo -e "    运行: ${CYAN}sudo ~/03-setup-https.sh your-domain.com${NC}"
echo ""

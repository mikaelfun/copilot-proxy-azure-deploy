#!/usr/bin/env bash
# ============================================================
#  Copilot Proxy + new-api — 一键部署安装脚本
#  由 ARM 模板 Custom Script Extension 自动调用
#  也可手动执行: sudo bash setup-all.sh
#
#  功能：安装 Docker、Node.js 22、Nginx、Certbot、
#        @jer-y/copilot-proxy、new-api Docker 容器，
#        并配置 Nginx 反向代理和 systemd 服务。
#
#  注意：Copilot Proxy 需要 GitHub OAuth 授权（设备码流程），
#        因此本脚本不会自动启动 copilot-proxy 服务，
#        需要用户 SSH 登录后手动完成授权。
# ============================================================

set -euo pipefail

# ========== 日志输出 ==========
# Custom Script Extension 环境下无 TTY，不使用颜色
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
step() { echo ""; echo "========================================"; echo "[STEP] $1"; echo "========================================"; }
ok()   { echo "[OK] $1"; }
warn() { echo "[WARN] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# ========== 检查权限 ==========
if [[ $EUID -ne 0 ]]; then
    fail "请使用 root 权限运行此脚本 (sudo)"
fi

log "开始安装 Copilot Proxy + new-api 环境..."

# ========== 读取参数 ==========
DOMAIN_NAME="${1:-}"
log "域名参数: ${DOMAIN_NAME:-（未指定，跳过 HTTPS 配置）}"

# ========== 1. 系统更新 ==========
step "1/7 更新系统软件包"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
ok "系统更新完成"

# ========== 2. 安装 Docker ==========
step "2/7 安装 Docker"

if command -v docker &>/dev/null; then
    warn "Docker 已安装，跳过"
else
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

    # 将默认用户加入 docker 组
    usermod -aG docker azureuser || true

    systemctl enable docker
    systemctl start docker
    ok "Docker 安装完成"
fi

# ========== 3. 安装 Node.js 22 ==========
step "3/7 安装 Node.js 22"

if command -v node &>/dev/null; then
    warn "Node.js 已安装 ($(node -v))，跳过"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
    ok "Node.js $(node -v) 安装完成"
fi

# ========== 4. 安装 Nginx + Certbot ==========
step "4/7 安装 Nginx 和 Certbot"

apt-get install -y -qq nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx
ok "Nginx 安装完成"

# ========== 5. 安装 Copilot Proxy ==========
step "5/7 安装 @jer-y/copilot-proxy"

npm install -g @jer-y/copilot-proxy
ok "copilot-proxy 安装完成"

# ========== 6. 部署 new-api Docker 容器 ==========
step "6/7 部署 new-api Docker 容器"

# 创建数据持久化目录
mkdir -p /opt/new-api/data

if docker ps -a --format '{{.Names}}' | grep -q '^new-api$'; then
    warn "new-api 容器已存在"
    if docker ps --format '{{.Names}}' | grep -q '^new-api$'; then
        warn "容器正在运行"
    else
        docker start new-api
        ok "已启动现有容器"
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

    ok "new-api 容器已启动"
fi

# ========== 7. 配置 systemd 服务 + Nginx ==========
step "7/7 配置 systemd 服务和 Nginx 反向代理"

# --- 创建 copilot-proxy systemd 服务（仅配置，不启动） ---
cat > /etc/systemd/system/copilot-proxy.service << 'EOF'
[Unit]
Description=Copilot Proxy - GitHub Copilot API Gateway
After=network.target docker.service
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/copilot-proxy start --port 15432
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable copilot-proxy
# 注意：不启动 copilot-proxy，需要用户先完成 GitHub OAuth 授权
ok "copilot-proxy systemd 服务配置完成（未启动，需先完成 GitHub OAuth）"

# --- 配置 Nginx HTTP 反向代理 ---
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

        # LLM 请求可能较慢，设置较长超时
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/new-api /etc/nginx/sites-enabled/new-api
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
ok "Nginx 反向代理配置完成"

# ========== 7/8 HTTPS 配置（如果提供了域名）==========
if [[ -n "$DOMAIN_NAME" ]]; then
    step "7/8 配置 HTTPS (Let's Encrypt)"

    # 更新 Nginx server_name
    sed -i "s/server_name _;/server_name ${DOMAIN_NAME};/" /etc/nginx/sites-available/new-api
    nginx -t && systemctl reload nginx

    # 申请 Let's Encrypt 证书（非交互模式）
    certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
        warn "Let's Encrypt 证书申请失败（DNS 可能尚未生效），稍后可手动运行："
        warn "  sudo certbot --nginx -d ${DOMAIN_NAME}"
    }

    # 设置自动续签
    systemctl enable certbot.timer 2>/dev/null || true
    ok "HTTPS 配置完成: https://${DOMAIN_NAME}"
else
    step "7/8 跳过 HTTPS（未提供域名）"
    warn "如需配置 HTTPS，部署后运行："
    warn "  sudo certbot --nginx -d your-domain.com"
fi

# ========== 8/8 完成 ==========

# ========== 获取公网 IP ==========
PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || echo "<PUBLIC_IP>")
ACCESS_URL="http://${PUBLIC_IP}"
if [[ -n "$DOMAIN_NAME" ]]; then
    ACCESS_URL="https://${DOMAIN_NAME}"
fi

# ========== 完成输出 ==========
echo ""
echo "========================================================"
echo "  ✅ 部署完成！"
echo "========================================================"
echo ""
echo "  已部署组件:"
echo "    ● Docker           — 运行中"
echo "    ● Node.js          — $(node -v)"
echo "    ● new-api          — ${ACCESS_URL}"
echo "    ● Nginx            — 反向代理 → new-api"
if [[ -n "$DOMAIN_NAME" ]]; then
echo "    ● HTTPS            — Let's Encrypt (${DOMAIN_NAME})"
fi
echo "    ○ Copilot Proxy    — 需要先完成 GitHub OAuth 授权"
echo ""
echo "  📝 还需一步 — SSH 登录 VM 完成 GitHub Copilot 授权:"
echo ""
echo "    ssh azureuser@${PUBLIC_IP}"
echo "    sudo copilot-proxy auth"
echo "    # 按照提示在浏览器中完成 GitHub 设备码授权"
echo "    # 授权成功后启动服务："
echo "    sudo systemctl start copilot-proxy"
echo ""
echo "  🔗 访问 new-api: ${ACCESS_URL}"
echo "     首次访问会提示创建管理员账号，请设置强密码。"
echo ""
echo "========================================================"

log "安装脚本执行完毕"

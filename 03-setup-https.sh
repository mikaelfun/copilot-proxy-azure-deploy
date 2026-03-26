#!/usr/bin/env bash
# ============================================================
#  Copilot Proxy + new-api — HTTPS 配置脚本 (Let's Encrypt)
#  用法: sudo ./03-setup-https.sh <域名>
#  示例: sudo ./03-setup-https.sh copilot.example.com
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

# ========== 参数检查 ==========
if [[ $# -lt 1 ]]; then
    echo -e "${RED}用法: sudo $0 <域名>${NC}"
    echo -e "示例: sudo $0 copilot.example.com"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    fail "请使用 sudo 运行此脚本"
fi

DOMAIN="$1"

echo -e "${MAGENTA}"
echo "═══════════════════════════════════════════════"
echo "  HTTPS 配置 — Let's Encrypt"
echo "  域名: $DOMAIN"
echo "═══════════════════════════════════════════════"
echo -e "${NC}"

# ========== 1. 检查 DNS 解析 ==========
step "检查域名 DNS 解析..."

VM_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "unknown")
DNS_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || echo "unresolved")

echo "  VM 公网 IP: $VM_IP"
echo "  DNS 解析  : $DNS_IP"

if [[ "$DNS_IP" != "$VM_IP" ]]; then
    warn "域名 DNS 解析 ($DNS_IP) 与 VM IP ($VM_IP) 不匹配"
    warn "请确保域名 A 记录已指向 $VM_IP"
    read -p "  是否继续？(y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "已取消"
        exit 0
    fi
else
    success "DNS 解析正确"
fi

# ========== 2. 配置 Nginx 虚拟主机 ==========
step "配置 Nginx 虚拟主机..."

cat > "/etc/nginx/sites-available/$DOMAIN" << NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # new-api 反向代理
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 长连接和超时设置（LLM 请求可能较慢）
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINXEOF

# 启用站点配置
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"

# 禁用 default 站点（如存在）
rm -f /etc/nginx/sites-enabled/default

# 测试 Nginx 配置
nginx -t || fail "Nginx 配置语法错误"

systemctl reload nginx
success "Nginx 虚拟主机配置完成"

# ========== 3. 获取 Let's Encrypt 证书 ==========
step "获取 Let's Encrypt SSL 证书..."

certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --redirect

if [[ $? -eq 0 ]]; then
    success "SSL 证书获取成功"
else
    fail "证书获取失败，请检查域名 DNS 和防火墙设置"
fi

# ========== 4. 配置自动续期 ==========
step "配置证书自动续期..."

# certbot 安装时通常已配置 systemd timer 或 cron
if systemctl list-timers | grep -q certbot; then
    success "certbot 自动续期 timer 已启用"
else
    # 添加 cron 作为备用
    CRON_LINE="0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
    (crontab -l 2>/dev/null | grep -v certbot; echo "$CRON_LINE") | crontab -
    success "已添加 cron 自动续期任务（每天凌晨 3 点检查）"
fi

# ========== 5. 验证 ==========
step "验证 HTTPS 配置..."

# 等待 Nginx 重载
sleep 2

HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "https://$DOMAIN" --max-time 10 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    success "HTTPS 访问正常 (HTTP $HTTP_CODE)"
else
    warn "HTTPS 验证返回 HTTP $HTTP_CODE，请手动检查"
fi

# ========== 完成 ==========
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✔ HTTPS 配置完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  访问地址: ${CYAN}https://$DOMAIN${NC}"
echo -e "  API 地址: ${CYAN}https://$DOMAIN/v1${NC}"
echo ""
echo -e "  证书信息:"
certbot certificates 2>/dev/null | grep -E "(Domains|Expiry)" | sed 's/^/    /'
echo ""

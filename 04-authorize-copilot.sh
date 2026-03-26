#!/usr/bin/env bash
# ============================================================
#  Copilot Proxy — OAuth 授权脚本
#  首次运行时需要通过 GitHub Device Flow 授权
#  用法: sudo ./04-authorize-copilot.sh
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

if [[ $EUID -ne 0 ]]; then
    fail "请使用 sudo 运行此脚本"
fi

PROXY_DIR="/opt/copilot-proxy/Copilot_Proxy"
VENV_DIR="/opt/copilot-proxy/venv"

echo -e "${MAGENTA}"
echo "═══════════════════════════════════════════════"
echo "  Copilot Proxy — GitHub OAuth 授权"
echo "═══════════════════════════════════════════════"
echo -e "${NC}"

# ========== 检查文件 ==========
step "检查 Copilot Proxy 文件..."

if [[ ! -f "$PROXY_DIR/main.py" ]]; then
    fail "未找到 $PROXY_DIR/main.py，请先运行 02-setup-vm.sh"
fi

if [[ ! -f "$VENV_DIR/bin/python" ]]; then
    fail "未找到虚拟环境 $VENV_DIR，请先运行 02-setup-vm.sh"
fi

success "文件检查通过"

# ========== 停止现有服务 ==========
step "停止现有 copilot-proxy 服务（如正在运行）..."

if systemctl is-active --quiet copilot-proxy 2>/dev/null; then
    systemctl stop copilot-proxy
    success "已停止现有服务"
else
    warn "服务未运行，跳过"
fi

# ========== 交互式启动 ==========
step "启动 Copilot Proxy 进行 OAuth 授权..."

echo ""
echo -e "  ${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${YELLOW}║  授权步骤：                                       ║${NC}"
echo -e "  ${YELLOW}║  1. 程序启动后会显示一个设备码 (device code)        ║${NC}"
echo -e "  ${YELLOW}║  2. 在浏览器中打开: https://github.com/login/device║${NC}"
echo -e "  ${YELLOW}║  3. 输入设备码并确认授权                           ║${NC}"
echo -e "  ${YELLOW}║  4. 授权成功后按 Ctrl+C 退出                      ║${NC}"
echo -e "  ${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}正在启动 Copilot Proxy...${NC}"
echo -e "  ${CYAN}请在下方输出中查找设备码${NC}"
echo ""
echo "────────────────────────────────────────────────"

cd "$PROXY_DIR"

# 使用 trap 捕获 Ctrl+C，优雅退出并启动 systemd 服务
trap 'echo -e "\n────────────────────────────────────────────────"; echo ""; step "启动 systemd 服务..."; systemctl start copilot-proxy; sleep 2; if systemctl is-active --quiet copilot-proxy; then success "copilot-proxy 服务已启动并在后台运行"; else warn "服务启动可能失败，请检查: sudo systemctl status copilot-proxy"; fi; echo ""; exit 0' INT

# 前台运行以显示设备码
"$VENV_DIR/bin/python" main.py

# 如果程序正常退出（不是 Ctrl+C）
echo ""
echo "────────────────────────────────────────────────"

step "启动 systemd 服务..."
systemctl start copilot-proxy
sleep 2

if systemctl is-active --quiet copilot-proxy; then
    success "copilot-proxy 服务已启动并在后台运行"
else
    warn "服务启动可能失败"
    echo -e "  查看日志: ${CYAN}sudo journalctl -u copilot-proxy -f --no-pager${NC}"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✔ 授权完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  服务状态: ${CYAN}sudo systemctl status copilot-proxy${NC}"
echo -e "  查看日志: ${CYAN}sudo journalctl -u copilot-proxy -f${NC}"
echo ""

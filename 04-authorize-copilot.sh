#!/usr/bin/env bash
# ============================================================
#  Copilot Proxy — GitHub 授权脚本
#  使用 copilot-proxy auth 命令完成 GitHub Device Flow 授权
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

echo -e "${MAGENTA}"
echo "═══════════════════════════════════════════════"
echo "  Copilot Proxy — GitHub 授权"
echo "═══════════════════════════════════════════════"
echo -e "${NC}"

# ========== 检查安装 ==========
step "检查 copilot-proxy 安装..."

if ! command -v copilot-proxy &>/dev/null; then
    fail "未找到 copilot-proxy 命令，请先运行 02-setup-vm.sh"
fi

success "copilot-proxy 已安装"

# ========== 停止现有服务 ==========
step "停止现有 copilot-proxy 服务（如正在运行）..."

if systemctl is-active --quiet copilot-proxy 2>/dev/null; then
    systemctl stop copilot-proxy
    success "已停止现有服务"
else
    warn "服务未运行，跳过"
fi

# ========== Device Flow 授权 ==========
step "启动 GitHub Device Flow 授权..."

echo ""
echo -e "  ${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${YELLOW}║  授权步骤：                                       ║${NC}"
echo -e "  ${YELLOW}║  1. 运行 copilot-proxy auth 获取设备码             ║${NC}"
echo -e "  ${YELLOW}║  2. 在浏览器中打开: https://github.com/login/device║${NC}"
echo -e "  ${YELLOW}║  3. 输入设备码并确认授权                           ║${NC}"
echo -e "  ${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}正在启动授权流程...${NC}"
echo ""
echo "────────────────────────────────────────────────"

# 执行授权命令
copilot-proxy auth

echo ""
echo "────────────────────────────────────────────────"

# ========== 首次启动（写入 token） ==========
step "首次启动 copilot-proxy 以保存 token..."

echo ""
echo -e "  ${YELLOW}请输入上一步获取的 GitHub Token:${NC}"
read -r -p "  Token: " GITHUB_TOKEN

if [[ -z "$GITHUB_TOKEN" ]]; then
    fail "Token 不能为空"
fi

echo ""
echo -e "  ${CYAN}使用 token 启动 copilot-proxy（后台模式）...${NC}"

# 使用 -d 后台模式启动一次，将 token 写入数据目录
copilot-proxy start --port 15432 --github-token "$GITHUB_TOKEN" -d

sleep 3

# 停止后台进程，交给 systemd 管理
pkill -f "copilot-proxy start" 2>/dev/null || true
sleep 1

# ========== 启动 systemd 服务 ==========
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
echo -e "  服务状态:   ${CYAN}sudo systemctl status copilot-proxy${NC}"
echo -e "  查看日志:   ${CYAN}copilot-proxy logs -f${NC}"
echo -e "  重启服务:   ${CYAN}sudo systemctl restart copilot-proxy${NC}"
echo ""

# Copilot Proxy + new-api 部署指南

## 一键部署（推荐）

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikaelfun%2Fcopilot-proxy-azure-deploy%2Fmaster%2Fazuredeploy.json)

### 部署步骤

1. 点击上方按钮 → Azure Portal 打开部署页面
2. 填写参数（SSH 公钥、VM 大小等）
3. 点击 "Review + Create" → "Create"
4. 等待部署完成（约 5-10 分钟）
5. SSH 登录 VM，运行 Copilot OAuth 授权：
   ```bash
   ssh azureuser@<部署输出中的IP>
   sudo copilot-proxy auth
   # 按提示在浏览器中完成 GitHub 授权
   # 授权成功后启动服务：
   sudo systemctl start copilot-proxy
   ```
6. 配置 new-api（参见下方"配置 new-api"章节）

### 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `adminUsername` | VM 管理员用户名 | `azureuser` |
| `adminSshKey` | SSH 公钥（`ssh-rsa AAAA...`） | 必填 |
| `dnsLabelPrefix` | 公网 IP DNS 前缀（可选） | 空 |
| `vmSize` | VM 规格 | `Standard_B2as_v2` |
| `location` | 部署区域 | 资源组所在区域 |

### 部署完成后的输出

| 输出项 | 说明 |
|--------|------|
| `publicIpAddress` | VM 公网 IP 地址 |
| `sshCommand` | SSH 连接命令 |
| `newApiUrl` | new-api 访问地址 |
| `fqdn` | DNS 域名（如已配置） |

> 💡 如果你更喜欢手动分步部署，请参考下方"手动部署步骤"章节。

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure VM (Standard_B2as_v2)                  │
│                      Ubuntu 24.04 LTS                           │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Nginx (端口 80/443)                    │   │
│  │              反向代理 + Let's Encrypt HTTPS               │   │
│  └─────────────────────┬────────────────────────────────────┘   │
│                        │                                        │
│                        ▼                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              new-api (端口 3000)                          │   │
│  │           LLM 网关 / API Key 管理                         │   │
│  │           Docker: calciumion/new-api:latest               │   │
│  └─────────────────────┬────────────────────────────────────┘   │
│                        │ 转发请求到 Copilot Proxy               │
│                        ▼                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │           Copilot Proxy (端口 15432)                      │   │
│  │      Node.js @jer-y/copilot-proxy / systemd 服务          │   │
│  │    支持 OpenAI + Anthropic 双格式 → GitHub Copilot API     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                        │                                        │
└────────────────────────┼────────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │  GitHub Copilot API  │
              │  (api.*.github      │
              │   copilot.com)      │
              └─────────────────────┘
```

**请求流程：**
```
OpenAI 兼容客户端 (GPT/Gemini)
  → Nginx (HTTPS 终止)
    → new-api (API Key 认证 + 用量管理)
      → Copilot Proxy /v1/chat/completions (OpenAI 格式)
        → GitHub Copilot API

Claude Code (Anthropic 原生格式)
  → Nginx (HTTPS 终止)
    → new-api (API Key 认证 + 用量管理)
      → Copilot Proxy /v1/messages (Anthropic 格式)
        → GitHub Copilot API
```

## 前置条件

1. **Azure 订阅** - 有权限创建 VM 资源
2. **GitHub 账号** - 已开通 GitHub Copilot（个人版或企业版均可）
3. **本地环境** - Windows + Azure CLI (`az`) + PowerShell 5.1+
4. **域名**（可选）- 如需 HTTPS 访问，需要一个已解析到 VM IP 的域名

## 费用估算

| 资源 | 规格 | 月费用（估算） |
|------|------|---------------|
| VM | Standard_B2as_v2 (2 vCPU, 4 GB RAM) | ~$27 |
| OS 磁盘 | 30GB StandardSSD | ~$3 |
| 公网 IP | Standard SKU | ~$2 |
| **合计** | | **~$32/月** |

> 💡 以上为美区价格，Mooncake 价格会有所不同。可按需选择更小/更大的 VM 规格。

## 文件清单

| 文件 | 说明 | 运行位置 |
|------|------|---------|
| `azuredeploy.json` | ARM 模板（一键部署） | Azure Portal |
| `azuredeploy.parameters.json` | ARM 参数示例文件 | Azure Portal / CLI |
| `scripts/setup-all.sh` | VM 自动安装脚本（ARM 模板调用） | VM 上 (自动) |
| `01-create-vm.ps1` | 创建 Azure VM（手动部署） | 本地 Windows (PowerShell) |
| `02-setup-vm.sh` | 安装 Docker/Node.js/Nginx/Copilot Proxy（手动部署） | VM 上 (SSH) |
| `03-setup-https.sh` | 配置 HTTPS (Let's Encrypt) | VM 上 (SSH) |
| `04-authorize-copilot.sh` | Copilot Proxy GitHub 授权（手动部署） | VM 上 (SSH) |
| `05-auto-restart.ps1` | 配置 VM 自动重启 | 本地 Windows (PowerShell) |

## 手动部署步骤

> 以下是分步手动部署方式，如已使用一键部署则可跳过。

### 第一步：创建 Azure VM

在本地 Windows PowerShell 中执行：

```powershell
# 基础用法（使用默认参数）
.\01-create-vm.ps1

# 自定义参数
.\01-create-vm.ps1 -ResourceGroup "rg-copilot" -VMName "vm-copilot" -Location "eastasia"

# 如果有域名，可以指定（后续配置 HTTPS 用）
.\01-create-vm.ps1 -DomainName "copilot.yourdomain.com"
```

脚本完成后会输出 VM 的公网 IP 地址。

### 第二步：上传脚本到 VM

```powershell
# 获取 VM 的 IP 地址
$vmIp = "YOUR_VM_IP"

# 上传所有脚本
scp 02-setup-vm.sh 03-setup-https.sh 04-authorize-copilot.sh azureuser@${vmIp}:~/
```

### 第三步：安装软件环境

SSH 登录到 VM 并执行安装脚本：

```bash
ssh azureuser@YOUR_VM_IP

# 添加执行权限并运行
chmod +x ~/02-setup-vm.sh ~/03-setup-https.sh ~/04-authorize-copilot.sh
sudo ~/02-setup-vm.sh
```

脚本将自动完成：
- Docker + Docker Compose 安装
- Node.js 22 + @jer-y/copilot-proxy 安装
- Nginx + Certbot 安装
- new-api Docker 容器启动
- systemd 服务配置

### 第四步：Copilot GitHub 授权

```bash
sudo ~/04-authorize-copilot.sh
```

按照屏幕提示：
1. 运行 `copilot-proxy auth` 获取设备码
2. 在浏览器中打开 `https://github.com/login/device`
3. 输入设备码并授权 GitHub Copilot 访问
4. 输入获取的 Token，服务将自动启动

### 第五步：配置 HTTPS（可选）

如果你有域名并且 DNS 已解析到 VM IP：

```bash
sudo ~/03-setup-https.sh your-domain.com
```

### 第六步：配置 new-api

1. 打开浏览器访问 `http://YOUR_VM_IP:3000`（或 HTTPS 域名）
2. 首次访问时会提示**创建管理员账号**，设置用户名和密码
3. **⚠️ 请使用强密码！**

#### NewAPI 渠道配置

Node.js 版 Copilot Proxy 同时支持 OpenAI (`/v1/chat/completions`) 和 Anthropic (`/v1/messages`) 两种格式，因此需要配置 **两个渠道**：

##### 渠道 1：Anthropic 类型（Claude 模型）

1. 进入 **渠道** → **添加新的渠道**
2. 配置如下：
   - **类型**：Anthropic (type=14)
   - **名称**：Copilot Proxy - Claude
   - **Base URL**：`http://host.docker.internal:15432`
   - **密钥**：任意值（如 `sk-copilot`，Copilot Proxy 不校验密钥）
   - **模型**：手动添加 Claude 模型
     ```
     claude-opus-4.6-1m, claude-opus-4.6, claude-opus-4.5,
     claude-sonnet-4.6, claude-sonnet-4.5, claude-sonnet-4, claude-haiku-4.5
     ```

> 💡 **为什么用 Anthropic 类型？** new-api 的 Anthropic 渠道会将 `/v1/messages` 请求透传给后端，
> Copilot Proxy 原生支持 Anthropic 格式，全程无格式转换。这解决了之前 OpenAI 渠道 + Claude 模型名映射
> 导致的格式转换 bug（如 Claude Code 重复回答问题）。

##### 渠道 2：OpenAI 类型（GPT/Gemini/Embedding 模型）

1. 进入 **渠道** → **添加新的渠道**
2. 配置如下：
   - **类型**：OpenAI (type=1)
   - **名称**：Copilot Proxy - OpenAI
   - **Base URL**：`http://host.docker.internal:15432`
   - **密钥**：任意值（如 `sk-copilot`）
   - **模型**：手动添加 GPT/Gemini 模型
     ```
     gpt-5.4, gpt-5.4-mini, gpt-5.3-codex, gpt-5.2-codex, gpt-5.2,
     gpt-5.1, gpt-5.1-codex, gpt-5.1-codex-mini, gpt-5.1-codex-max, gpt-5-mini,
     gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4,
     gemini-3.1-pro-preview, gemini-3-pro-preview, gemini-3-flash-preview, gemini-2.5-pro
     ```
3. 点击 **提交**

#### 创建 API Key

1. 进入 **令牌** → **添加新的令牌**
2. 设置名称和额度
3. 复制生成的 API Key（格式：`sk-xxx`）

### 使用方式

#### OpenAI 兼容客户端

配置：
- **API Base URL**：`https://your-domain.com/v1` 或 `http://YOUR_VM_IP:3000/v1`
- **API Key**：new-api 中创建的令牌

示例（curl）：

```bash
curl https://your-domain.com/v1/chat/completions \
  -H "Authorization: Bearer sk-your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

示例（Python openai SDK）：

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-your-api-key",
    base_url="https://your-domain.com/v1"
)

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)
```

#### Claude Code 配置

Claude Code 原生使用 Anthropic Messages 格式（`/v1/messages`），通过 Anthropic 渠道透传，无需格式转换。

编辑 `~/.claude/settings.json`，添加环境变量：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-domain.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-your-newapi-token"
  }
}
```

> 💡 `ANTHROPIC_BASE_URL` 不需要带 `/v1` 后缀，Claude Code 会自动拼接 `/v1/messages`。
> `ANTHROPIC_AUTH_TOKEN` 使用 new-api 中创建的 API Key。

## 故障排查

### 常见问题

#### 1. Copilot Proxy 无法获取 Token

```bash
# 检查服务状态
sudo systemctl status copilot-proxy

# 查看日志
copilot-proxy logs -f

# 重新授权
sudo ~/04-authorize-copilot.sh
```

#### 2. new-api 无法连接 Copilot Proxy

```bash
# 检查 Copilot Proxy 是否在监听
curl http://localhost:15432/v1/chat/completions -X POST \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"test"}]}'

# 检查 Docker 网络（从容器内访问宿主机）
docker exec -it new-api curl http://host.docker.internal:15432/
```

#### 3. HTTPS 证书问题

```bash
# 检查证书状态
sudo certbot certificates

# 手动续期
sudo certbot renew --dry-run

# 检查 Nginx 配置
sudo nginx -t
```

#### 4. 模型返回错误

```bash
# 查看 Copilot Proxy 最近日志
copilot-proxy logs -f

# 检查服务状态
copilot-proxy status
```

#### 5. VM 重启后服务未自动启动

```bash
# 检查服务是否启用了自动启动
sudo systemctl is-enabled copilot-proxy
sudo systemctl is-enabled docker

# 手动启动
sudo systemctl start copilot-proxy
sudo docker start new-api
```

### 日志位置

| 组件 | 日志查看方式 |
|------|------------|
| Copilot Proxy | `copilot-proxy logs -f` 或 `sudo journalctl -u copilot-proxy -f` |
| new-api | `sudo docker logs -f new-api` |
| Nginx | `sudo tail -f /var/log/nginx/error.log` |

## 安全注意事项

1. **⚠️ 首次访问 new-api 时会提示创建管理员账号**，请设置强密码
2. **NSG 规则**：生产环境建议限制 3000 端口的来源 IP，仅通过 Nginx 反代访问
3. **OAuth Token**：Token 保存在 `~/.local/share/copilot-proxy/` 数据目录中
4. **HTTPS**：强烈建议配置 HTTPS，防止 API Key 在传输中泄露
5. **定期更新**：
   ```bash
   # 更新 new-api
   sudo docker pull calciumion/new-api:latest
   sudo docker stop new-api && sudo docker rm new-api
   # 重新运行 02-setup-vm.sh 中的 docker run 命令

   # 更新 Copilot Proxy
   sudo npm install -g @jer-y/copilot-proxy
   sudo systemctl restart copilot-proxy
   ```

## 维护命令速查

```bash
# Copilot Proxy 管理
copilot-proxy status                # 查看状态
copilot-proxy logs -f               # 查看日志（实时）
copilot-proxy restart               # 重启

# systemd 服务管理
sudo systemctl {start|stop|restart|status} copilot-proxy

# Docker 容器管理
sudo docker {start|stop|restart} new-api

# 查看日志
sudo journalctl -u copilot-proxy -f --no-pager
sudo docker logs -f new-api

# 检查端口监听
sudo ss -tlnp | grep -E '3000|15432|80|443'

# 磁盘使用
df -h
docker system df
```

## 第五步：配置 VM 自动重启（可选）

Azure 内部订阅的治理策略可能会自动关闭 VM。此脚本部署 Azure Automation 定时检查 VM 状态，关机后自动拉起。

### 原理

```
每小时 xx:03 触发 → 检查 Tag（今天启动过？）→ 检查电源状态
  ├─ Running → 跳过
  ├─ Deallocated → 启动 VM + 写 Tag（当天不再重复启动）
  └─ 已启动过 → 跳过
```

### 部署

```powershell
.\05-auto-restart.ps1 `
  -SubscriptionId "你的订阅ID" `
  -ResourceGroup "copilot-proxy-rg" `
  -VmName "copilot-vm" `
  -Region "eastasia" `
  -TimezoneOffset 8 `
  -MinuteOfHour 3
```

### 资源说明

| 组件 | 说明 |
|------|------|
| Automation Account | `{VM_NAME}-AutoRestart`，Free 层（500分钟/月免费，实际用 ~12分钟/月） |
| Managed Identity | VM Contributor + Tag Contributor，scope 限定资源组 |
| Runbook | PowerShell 7.2，幂等设计（Tag 控制每天只启动一次） |
| Schedule | 24 个，每小时 xx:03 UTC 触发 |

### 清理

```bash
az automation account delete --name {VM_NAME}-AutoRestart --resource-group {RESOURCE_GROUP} --yes
```

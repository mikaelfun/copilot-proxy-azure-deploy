# Copilot Proxy + new-api 部署指南

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
│  │          Python Flask / systemd 服务                       │   │
│  │       OAuth 认证 → GitHub Copilot API                     │   │
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
用户 (OpenAI 兼容客户端)
  → Nginx (HTTPS 终止)
    → new-api (API Key 认证 + 用量管理)
      → Copilot Proxy (Copilot OAuth Token 管理)
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
| `01-create-vm.ps1` | 创建 Azure VM | 本地 Windows (PowerShell) |
| `02-setup-vm.sh` | 安装 Docker/Nginx/Copilot Proxy | VM 上 (SSH) |
| `03-setup-https.sh` | 配置 HTTPS (Let's Encrypt) | VM 上 (SSH) |
| `04-authorize-copilot.sh` | Copilot OAuth 授权 | VM 上 (SSH) |
| `copilot_proxy_patches.py` | Copilot Proxy 代码补丁 | VM 上 (自动调用) |

## 部署步骤

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
scp 02-setup-vm.sh 03-setup-https.sh 04-authorize-copilot.sh copilot_proxy_patches.py azureuser@${vmIp}:~/
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
- Python3 虚拟环境配置
- Nginx + Certbot 安装
- Copilot Proxy 克隆与补丁
- new-api Docker 容器启动
- systemd 服务配置

### 第四步：Copilot OAuth 授权

```bash
sudo ~/04-authorize-copilot.sh
```

按照屏幕提示：
1. 在浏览器中打开 `https://github.com/login/device`
2. 输入显示的设备码
3. 授权 GitHub Copilot 访问
4. 等待授权完成，服务将自动重启

### 第五步：配置 HTTPS（可选）

如果你有域名并且 DNS 已解析到 VM IP：

```bash
sudo ~/03-setup-https.sh your-domain.com
```

### 第六步：配置 new-api

1. 打开浏览器访问 `http://YOUR_VM_IP:3000`（或 HTTPS 域名）
2. 首次访问时会提示**创建管理员账号**，设置用户名和密码
3. **⚠️ 请使用强密码！**

#### 添加 Copilot 渠道

1. 进入 **渠道** → **添加新的渠道**
2. 配置如下：
   - **类型**：OpenAI
   - **名称**：Copilot Proxy
   - **Base URL**：`http://host.docker.internal:15432`
   - **密钥**：任意值（如 `sk-copilot`，Copilot Proxy 不校验密钥）
   - **模型**：手动添加以下模型
     ```
     claude-opus-4.6-1m, claude-opus-4.6, claude-opus-4.5,
     claude-sonnet-4.6, claude-sonnet-4.5, claude-sonnet-4, claude-haiku-4.5,
     gpt-5.4, gpt-5.4-mini, gpt-5.3-codex, gpt-5.2-codex, gpt-5.2,
     gpt-5.1, gpt-5.1-codex, gpt-5.1-codex-mini, gpt-5.1-codex-max, gpt-5-mini,
     gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4,
     gemini-3.1-pro-preview, gemini-3-pro-preview, gemini-3-flash-preview, gemini-2.5-pro
     ```
3. 点击 **提交**
4. 测试渠道连接

> ⚠️ **重要：Claude 模型名映射**
> 
> new-api 检测到模型名含 `claude-` 时，会自动切换为 Anthropic 格式（`/v1/messages`），
> 但 Copilot Proxy 只支持 OpenAI 格式（`/chat/completions`），导致 404 错误。
> 
> **解决方案**：使用模型名映射，用不含 `claude-` 的自定义名称：
> 
> 1. 在渠道的模型列表中，用自定义名替代 Claude 原始名，例如：
>    ```
>    copilot-opus-1m, copilot-opus, copilot-opus-45,
>    copilot-sonnet, copilot-sonnet-45, copilot-sonnet-4, copilot-haiku
>    ```
> 2. 在渠道设置的**「模型重定向」**中配置映射：
>    ```
>    copilot-opus-1m => claude-opus-4.6-1m
>    copilot-opus => claude-opus-4.6
>    copilot-opus-45 => claude-opus-4.5
>    copilot-sonnet => claude-sonnet-4.6
>    copilot-sonnet-45 => claude-sonnet-4.5
>    copilot-sonnet-4 => claude-sonnet-4
>    copilot-haiku => claude-haiku-4.5
>    ```
> 3. 这样 new-api 用 OpenAI 格式发送请求，而 Copilot Proxy 收到的 model 参数仍是正确的 Claude 模型名
>
> GPT 和 Gemini 模型**无需映射**，直接使用原始名称即可。
> 
> **渠道测试注意**：测试时 Endpoint Type 请选择 **Auto-detect** 或 **OpenAI**，不要选 Anthropic。
> 如果测试显示 Failed 但实际 Playground 能用，属于正常现象（测试使用非流式请求，某些模型仅支持流式）。

#### 创建 API Key

1. 进入 **令牌** → **添加新的令牌**
2. 设置名称和额度
3. 复制生成的 API Key（格式：`sk-xxx`）

### 使用方式

使用 OpenAI 兼容客户端，配置：
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

## 补丁说明

`copilot_proxy_patches.py` 对原始 Copilot Proxy 做了以下修改：

| 补丁 | 说明 |
|------|------|
| 动态 API 端点 | 从 token 响应的 `endpoints.api` 字段读取 API 地址，兼容企业版和个人版 |
| 去除 `/v1/` 前缀 | new-api 发送请求时会带 `/v1/`，但 Copilot API 不需要这个前缀 |
| GPT-5.x 路由 | GPT-5.x 系列模型需要使用 `/responses` 端点而非 `/chat/completions` |

## 故障排查

### 常见问题

#### 1. Copilot Proxy 无法获取 Token

```bash
# 检查服务状态
sudo systemctl status copilot-proxy

# 查看日志
sudo journalctl -u copilot-proxy -f --no-pager

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

#### 4. GPT-5.x 模型返回错误

GPT-5.x 系列模型使用 `/responses` 端点。如果返回错误，检查：

```bash
# 查看 Copilot Proxy 日志中的请求转换
sudo journalctl -u copilot-proxy --since "5 minutes ago" --no-pager

# 确认补丁已正确应用
grep "RESPONSES_MODELS" /opt/copilot-proxy/Copilot_Proxy/main.py
grep "responses_to_chat" /opt/copilot-proxy/Copilot_Proxy/main.py
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
| Copilot Proxy | `sudo journalctl -u copilot-proxy -f` |
| new-api | `sudo docker logs -f new-api` |
| Nginx | `sudo tail -f /var/log/nginx/error.log` |

## 安全注意事项

1. **⚠️ 立即修改 new-api 默认密码**（默认 root/123456）
2. **NSG 规则**：生产环境建议限制 3000 端口的来源 IP，仅通过 Nginx 反代访问
3. **OAuth Token**：Token 保存在 Copilot Proxy 进程内存中，不写入磁盘
4. **HTTPS**：强烈建议配置 HTTPS，防止 API Key 在传输中泄露
5. **定期更新**：
   ```bash
   # 更新 new-api
   sudo docker pull calciumion/new-api:latest
   sudo docker stop new-api && sudo docker rm new-api
   # 重新运行 02-setup-vm.sh 中的 docker run 命令

   # 更新 Copilot Proxy
   cd /opt/copilot-proxy/Copilot_Proxy && sudo git pull
   sudo python3 ~/copilot_proxy_patches.py
   sudo systemctl restart copilot-proxy
   ```

## 维护命令速查

```bash
# 服务管理
sudo systemctl {start|stop|restart|status} copilot-proxy
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

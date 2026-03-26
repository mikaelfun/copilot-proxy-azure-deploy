<#
.SYNOPSIS
    创建 Azure VM 用于部署 Copilot Proxy + new-api

.DESCRIPTION
    创建 Ubuntu 24.04 VM，配置 NSG 规则，输出公网 IP。

.PARAMETER ResourceGroup
    资源组名称（默认: rg-copilot-proxy）

.PARAMETER VMName
    虚拟机名称（默认: vm-copilot-proxy）

.PARAMETER Location
    Azure 区域（默认: eastasia）

.PARAMETER VMSize
    VM 规格（默认: Standard_B2as_v2）

.PARAMETER DomainName
    可选，域名（用于后续 HTTPS 配置）

.EXAMPLE
    .\01-create-vm.ps1
    .\01-create-vm.ps1 -ResourceGroup "my-rg" -VMName "my-vm" -Location "southeastasia"
#>

param(
    [string]$ResourceGroup = "rg-copilot-proxy",
    [string]$VMName = "vm-copilot-proxy",
    [string]$Location = "eastasia",
    [string]$VMSize = "Standard_B2as_v2",
    [string]$DomainName = ""
)

$ErrorActionPreference = "Stop"

# ========== 辅助函数 ==========

function Write-Step {
    param([string]$Message)
    Write-Host "`n▶ $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✔ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✘ $Message" -ForegroundColor Red
}

# ========== 前置检查 ==========

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  Copilot Proxy + new-api — Azure VM 创建脚本   " -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Magenta

Write-Step "检查 Azure CLI 登录状态..."

try {
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Success "已登录: $($account.user.name) (订阅: $($account.name))"
} catch {
    Write-Warn "未登录 Azure CLI，正在启动登录..."
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Azure CLI 登录失败，请手动执行 'az login'"
        exit 1
    }
    $account = az account show | ConvertFrom-Json
    Write-Success "登录成功: $($account.user.name)"
}

# ========== 显示配置 ==========

Write-Step "部署配置:"
Write-Host "  资源组  : $ResourceGroup"
Write-Host "  VM 名称 : $VMName"
Write-Host "  区域    : $Location"
Write-Host "  规格    : $VMSize"
if ($DomainName) {
    Write-Host "  域名    : $DomainName"
}

# ========== 创建资源组 ==========

Write-Step "创建资源组: $ResourceGroup ..."

$rgExists = az group exists --name $ResourceGroup 2>&1
if ($rgExists -eq "true") {
    Write-Warn "资源组 $ResourceGroup 已存在，跳过创建"
} else {
    az group create --name $ResourceGroup --location $Location --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "资源组创建失败"
        exit 1
    }
    Write-Success "资源组创建完成"
}

# ========== 创建 VM ==========

Write-Step "创建虚拟机: $VMName（可能需要 2-5 分钟）..."

$vmParams = @(
    "vm", "create",
    "--resource-group", $ResourceGroup,
    "--name", $VMName,
    "--location", $Location,
    "--size", $VMSize,
    "--image", "Canonical:ubuntu-24_04-lts:server:latest",
    "--admin-username", "azureuser",
    "--generate-ssh-keys",
    "--os-disk-size-gb", "30",
    "--storage-sku", "StandardSSD_LRS",
    "--public-ip-sku", "Standard",
    "--nsg", "$VMName-nsg",
    "--output", "json"
)

$vmResult = az @vmParams 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "VM 创建失败:`n$vmResult"
    exit 1
}

$vmInfo = $vmResult | ConvertFrom-Json
$publicIp = $vmInfo.publicIpAddress
Write-Success "VM 创建完成，公网 IP: $publicIp"

# ========== 配置 NSG 规则（NIC 级别） ==========

Write-Step "配置 NSG 规则（NIC 级别）..."

$nsgName = "$VMName-nsg"

# 获取现有规则，避免重复创建
$existingRules = az network nsg rule list --resource-group $ResourceGroup --nsg-name $nsgName --output json 2>&1 | ConvertFrom-Json
$existingRuleNames = $existingRules | ForEach-Object { $_.name }

$rules = @(
    @{ Name = "Allow-HTTP";   Port = "80";   Priority = 1001; Desc = "HTTP 入站" },
    @{ Name = "Allow-HTTPS";  Port = "443";  Priority = 1002; Desc = "HTTPS 入站" },
    @{ Name = "Allow-NewAPI"; Port = "3000"; Priority = 1003; Desc = "new-api 入站" }
)

foreach ($rule in $rules) {
    if ($existingRuleNames -contains $rule.Name) {
        Write-Warn "规则 $($rule.Name) 已存在，跳过"
        continue
    }
    az network nsg rule create `
        --resource-group $ResourceGroup `
        --nsg-name $nsgName `
        --name $rule.Name `
        --priority $rule.Priority `
        --direction Inbound `
        --access Allow `
        --protocol Tcp `
        --destination-port-ranges $rule.Port `
        --source-address-prefixes "*" `
        --output none 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "规则 $($rule.Name) 创建可能失败，请手动检查"
    } else {
        Write-Success "$($rule.Desc) (端口 $($rule.Port)) — 已添加"
    }
}

# ========== 配置子网级 NSG（如存在） ==========

Write-Step "检查子网级 NSG 配置..."

$vnetList = az network vnet list --resource-group $ResourceGroup --output json 2>&1 | ConvertFrom-Json

if ($vnetList -and $vnetList.Count -gt 0) {
    $vnet = $vnetList[0]
    $vnetName = $vnet.name

    $subnets = az network vnet subnet list --resource-group $ResourceGroup --vnet-name $vnetName --output json 2>&1 | ConvertFrom-Json

    foreach ($subnet in $subnets) {
        $subnetNsg = $subnet.networkSecurityGroup
        if ($subnetNsg -and $subnetNsg.id -and ($subnetNsg.id -notmatch $nsgName)) {
            $subnetNsgName = ($subnetNsg.id -split "/")[-1]
            Write-Warn "子网 '$($subnet.name)' 关联了独立 NSG: $subnetNsgName"
            Write-Host "    正在向子网 NSG 添加规则..."

            foreach ($rule in $rules) {
                $subnetExistingRules = az network nsg rule list --resource-group $ResourceGroup --nsg-name $subnetNsgName --output json 2>&1 | ConvertFrom-Json
                $subnetRuleNames = $subnetExistingRules | ForEach-Object { $_.name }

                if ($subnetRuleNames -contains $rule.Name) {
                    Write-Warn "    子网 NSG 规则 $($rule.Name) 已存在，跳过"
                    continue
                }

                az network nsg rule create `
                    --resource-group $ResourceGroup `
                    --nsg-name $subnetNsgName `
                    --name $rule.Name `
                    --priority $rule.Priority `
                    --direction Inbound `
                    --access Allow `
                    --protocol Tcp `
                    --destination-port-ranges $rule.Port `
                    --source-address-prefixes "*" `
                    --output none 2>&1 | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    Write-Success "    子网 NSG: $($rule.Desc) (端口 $($rule.Port)) — 已添加"
                }
            }
        } else {
            Write-Success "子网 '$($subnet.name)' 使用与 NIC 相同的 NSG 或无独立 NSG"
        }
    }
} else {
    Write-Warn "未找到 VNet 信息，跳过子网 NSG 检查"
}

# ========== 输出结果 ==========

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✔ VM 创建完成！" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  公网 IP : $publicIp" -ForegroundColor White
Write-Host "  SSH 连接: ssh azureuser@$publicIp" -ForegroundColor White
Write-Host ""
Write-Host "  下一步操作:" -ForegroundColor Yellow
Write-Host "  1. 上传脚本到 VM:" -ForegroundColor Yellow
Write-Host "     scp 02-setup-vm.sh 03-setup-https.sh 04-authorize-copilot.sh copilot_proxy_patches.py azureuser@${publicIp}:~/" -ForegroundColor Gray
Write-Host "  2. SSH 登录并执行安装:" -ForegroundColor Yellow
Write-Host "     ssh azureuser@$publicIp" -ForegroundColor Gray
Write-Host "     chmod +x ~/02-setup-vm.sh && sudo ~/02-setup-vm.sh" -ForegroundColor Gray

if ($DomainName) {
    Write-Host ""
    Write-Host "  域名: $DomainName" -ForegroundColor Yellow
    Write-Host "  请将域名 A 记录指向: $publicIp" -ForegroundColor Yellow
}

Write-Host ""

<#
.SYNOPSIS
    部署 Azure Automation 定时检查并自动重启 VM。
    适用于 Azure 内部订阅（MCAPS/FDPO）VM 被治理策略自动关机的场景。

.DESCRIPTION
    创建 Automation Account + Managed Identity + Runbook + 每小时定时触发。
    VM 被关机后最多 1 小时内自动拉起，同一天不会重复启动（Tag 幂等控制）。

.PARAMETER SubscriptionId
    Azure 订阅 ID
.PARAMETER ResourceGroup
    VM 所在资源组
.PARAMETER VmName
    虚拟机名称
.PARAMETER Region
    VM 所在区域（如 eastasia）
.PARAMETER TimezoneOffset
    时区偏移（默认 +8，北京/新加坡）
.PARAMETER MinuteOfHour
    每小时第几分钟执行（默认 3）

.EXAMPLE
    .\05-auto-restart.ps1 -SubscriptionId "xxx" -ResourceGroup "copilot-proxy-rg" -VmName "copilot-vm" -Region "eastasia"
#>

param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Region,
    [int] $TimezoneOffset = 8,
    [int] $MinuteOfHour = 3
)

$ErrorActionPreference = "Stop"
$AA = "$VmName-AutoRestart"
$BASE = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AA"

Write-Host "=== Step 1: Create Automation Account ===" -ForegroundColor Cyan
$body = "{`"location`":`"$Region`",`"properties`":{`"sku`":{`"name`":`"Free`"}},`"identity`":{`"type`":`"SystemAssigned`"}}"
$result = az rest --method put --url "$BASE`?api-version=2023-11-01" --headers "Content-Type=application/json" --body $body | ConvertFrom-Json
$principalId = $result.identity.principalId
Write-Host "  Automation Account: $AA"
Write-Host "  Principal ID: $principalId" -ForegroundColor Green

Write-Host "`n=== Step 2: Assign Roles ===" -ForegroundColor Cyan
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Virtual Machine Contributor" --scope $scope | Out-Null
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Tag Contributor" --scope $scope | Out-Null
Write-Host "  VM Contributor + Tag Contributor assigned" -ForegroundColor Green

Write-Host "`n=== Step 3: Create Runbook ===" -ForegroundColor Cyan
$rbBody = '{\"location\":\"' + $Region + '\",\"properties\":{\"runbookType\":\"PowerShell72\",\"description\":\"Check if VM is deallocated and auto-restart\",\"logProgress\":false,\"logVerbose\":false}}'
az rest --method put --url "$BASE/runbooks/CheckAndRestartVM?api-version=2023-11-01" --headers "Content-Type=application/json" --body $rbBody | Out-Null
Write-Host "  Runbook created" -ForegroundColor Green

Write-Host "`n=== Step 4: Upload & Publish Runbook Script ===" -ForegroundColor Cyan
$scriptContent = @"
Connect-AzAccount -Identity | Out-Null

`$resourceGroup = "$ResourceGroup"
`$vmName = "$VmName"
`$tagKey = "LastAutoRestart"
`$tzOffset = $TimezoneOffset

`$today = (Get-Date).ToUniversalTime().AddHours(`$tzOffset).ToString("yyyy-MM-dd")
Write-Output "Today (UTC+`${tzOffset}): `$today"

`$vm = Get-AzVM -ResourceGroupName `$resourceGroup -Name `$vmName
`$lastRestart = `$vm.Tags[`$tagKey]
Write-Output "LastAutoRestart tag: `$lastRestart"

if (`$lastRestart -eq `$today) {
    Write-Output "Already restarted today (`$today). Skipping."
    exit 0
}

`$vmStatus = Get-AzVM -ResourceGroupName `$resourceGroup -Name `$vmName -Status
`$powerState = (`$vmStatus.Statuses | Where-Object { `$_.Code -like "PowerState/*" }).Code
Write-Output "Current power state: `$powerState"

if (`$powerState -eq "PowerState/running") {
    Write-Output "VM is running. No action needed."
    exit 0
}

if (`$powerState -eq "PowerState/deallocated" -or `$powerState -eq "PowerState/stopped") {
    Write-Output "VM is `$powerState. Starting VM..."
    Start-AzVM -ResourceGroupName `$resourceGroup -Name `$vmName
    Write-Output "VM started successfully."

    `$tags = `$vm.Tags
    if (`$null -eq `$tags) { `$tags = @{} }
    `$tags[`$tagKey] = `$today
    Update-AzTag -ResourceId `$vm.Id -Tag `$tags -Operation Merge
    Write-Output "Tag '`$tagKey' set to '`$today'."
} else {
    Write-Output "VM is in unexpected state: `$powerState. No action taken."
}
"@

$tmpFile = "$env:TEMP\CheckAndRestartVM.ps1"
$scriptContent | Out-File -FilePath $tmpFile -Encoding utf8NoBOM
az rest --method put --url "$BASE/runbooks/CheckAndRestartVM/draft/content?api-version=2023-11-01" --headers "Content-Type=text/powershell" --body "@$tmpFile" | Out-Null
az rest --method post --url "$BASE/runbooks/CheckAndRestartVM/publish?api-version=2023-11-01" --headers "Content-Type=application/json" | Out-Null
Remove-Item $tmpFile -Force
Write-Host "  Runbook published" -ForegroundColor Green

Write-Host "`n=== Step 5: Create Hourly Schedules (xx:$($MinuteOfHour.ToString('D2')) UTC) ===" -ForegroundColor Cyan
$startDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
$mm = $MinuteOfHour.ToString("D2")

foreach ($h in 0..23) {
    $hh = $h.ToString("D2")
    $schedName = "Hourly-UTC$hh$mm"

    $schedBody = "{`"properties`":{`"startTime`":`"${startDate}T${hh}:${mm}:00+00:00`",`"frequency`":`"Day`",`"interval`":1,`"timeZone`":`"UTC`"}}"
    az rest --method put --url "$BASE/schedules/$schedName`?api-version=2023-11-01" --headers "Content-Type=application/json" --body $schedBody 2>&1 | Out-Null

    $jobSchedId = [guid]::NewGuid().ToString()
    $linkBody = "{`"properties`":{`"runbook`":{`"name`":`"CheckAndRestartVM`"},`"schedule`":{`"name`":`"$schedName`"}}}"
    az rest --method put --url "$BASE/jobSchedules/$jobSchedId`?api-version=2023-11-01" --headers "Content-Type=application/json" --body $linkBody 2>&1 | Out-Null

    Write-Host "  $schedName" -ForegroundColor Gray
}
Write-Host "  24 schedules created" -ForegroundColor Green

Write-Host "`n=== Step 6: Test Run ===" -ForegroundColor Cyan
$jobId = [guid]::NewGuid().ToString()
$jobBody = '{\"properties\":{\"runbook\":{\"name\":\"CheckAndRestartVM\"}}}'
az rest --method put --url "$BASE/jobs/$jobId`?api-version=2023-11-01" --headers "Content-Type=application/json" --body $jobBody | Out-Null
Write-Host "  Job started: $jobId"
Write-Host "  Waiting 45s..." -ForegroundColor Gray
Start-Sleep 45

$job = az rest --method get --url "$BASE/jobs/$jobId`?api-version=2023-11-01" | ConvertFrom-Json
Write-Host "  Status: $($job.properties.status)" -ForegroundColor $(if ($job.properties.status -eq "Completed") { "Green" } else { "Yellow" })

$output = az rest --method get --url "$BASE/jobs/$jobId/output?api-version=2023-11-01" 2>&1
Write-Host "  Output: $output"

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host "  VM '$VmName' will be auto-restarted within 1 hour if stopped."
Write-Host "  Schedules run at xx:$mm UTC every hour."
Write-Host "  To clean up: az automation account delete --name $AA --resource-group $ResourceGroup --yes"

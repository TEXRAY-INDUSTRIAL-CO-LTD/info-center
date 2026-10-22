<#
.SYNOPSIS
  安裝「準時觸發更新」:存權杖、建立工作排程。只需執行一次;換權杖時重跑即可。

.DESCRIPTION
  1. 詢問 GitHub 權杖(輸入時不顯示),先向 GitHub 驗證可用,再存成 $TokenFile,
     並把檔案權限限縮成只有 SYSTEM 與系統管理員可讀。
  2. 建立工作排程 TEXRAY-InfoCenter-Trigger:週一至週五 09:23、16:47、18:43,
     以 SYSTEM 身分執行 trigger-update.ps1。
  3. 詢問是否立刻試跑一次。

  必須「以系統管理員身分」開 PowerShell 執行。
  注意:此檔必須以「UTF-8 含 BOM」存檔,Windows PowerShell 5.1 才不會把中文讀成亂碼。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\install-trigger-task.ps1
#>
param(
  [string]$TokenFile     = 'C:\ProgramData\TEXRAY\github-token.txt',
  [string]$TriggerScript = 'D:\WebSites\_scripts\trigger-update.ps1',
  [string]$Repo          = 'TEXRAY-INDUSTRIAL-CO-LTD/info-center',
  [string]$TaskName      = 'TEXRAY-InfoCenter-Trigger',
  [string[]]$Times       = @('09:23', '16:47', '18:43')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw '請以「系統管理員身分」開啟 PowerShell 再執行' }
if (-not (Test-Path $TriggerScript)) { throw "找不到 $TriggerScript,請先下載 trigger-update.ps1" }

# 排程時間以這台主機的時區為準,不是台北時間就要提醒
$tz = [TimeZoneInfo]::Local
if ($tz.BaseUtcOffset -ne [TimeSpan]::FromHours(8)) {
  Write-Warning "這台主機的時區是 $($tz.DisplayName),不是 UTC+8;排程時間 $($Times -join '、') 會照主機時區執行"
}

# ---- 1. 權杖 ----
$secure = Read-Host '請貼上 GitHub 權杖(github_pat_ 開頭,輸入時不會顯示)' -AsSecureString
$token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()
if ($token -notmatch '^github_pat_') { throw '這不是 fine-grained 權杖(應以 github_pat_ 開頭)' }

# 先驗證再存檔:權杖錯了不要覆蓋掉原本能用的那組
$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'texray-intranet-trigger'
}
try {
  $resp = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo" -Headers $headers -UseBasicParsing -TimeoutSec 60
}
catch {
  throw "權杖驗證失敗(權杖錯誤、已過期,或主機連不到 api.github.com):$($_.Exception.Message)"
}
$expires = $resp.Headers['github-authentication-token-expiration']
if ($expires) { Write-Output "權杖有效,到期日:$expires(到期前要重新產生並重跑這支腳本)" }
else { Write-Output '權杖有效' }

$dir = Split-Path $TokenFile
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Content -Path $TokenFile -Value $token -Encoding ASCII -NoNewline
# 移除繼承權限,只留 SYSTEM 與系統管理員(使用 SID,中英文版 Windows 皆適用)
icacls $TokenFile /inheritance:r /grant:r '*S-1-5-18:(R)' '*S-1-5-32-544:(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "設定 $TokenFile 權限失敗" }
Write-Output "權杖已存到 $TokenFile(只有 SYSTEM 與系統管理員可讀)"

# ---- 2. 工作排程 ----
$days     = 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
$triggers = foreach ($t in $Times) { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $t }
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$TriggerScript`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# StartWhenAvailable:主機在排定時間關機或忙碌,開機後補跑一次
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
  -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "已建立工作排程 ${TaskName}:週一至週五 $($Times -join '、')"

# ---- 3. 試跑 ----
$ans = Read-Host '要立刻試跑一次嗎?會觸發一次 GitHub 更新並同步網站,約 1~2 分鐘 (Y/N)'
if ($ans -match '^[Yy]') {
  Start-ScheduledTask -TaskName $TaskName
  Write-Output '已開始。等 1~2 分鐘後查看 D:\WebSites\_deploy\trigger-update.log,'
  Write-Output '最後一行出現「已同步到內網網站」即成功。'
}

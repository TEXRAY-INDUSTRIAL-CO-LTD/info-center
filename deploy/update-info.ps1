<#
.SYNOPSIS
  從 GitHub 下載 TEXRAY 綜合資訊中心的最新版本,同步到 IIS 網站資料夾。

.DESCRIPTION
  給 Windows 工作排程器定時執行(建議每小時一次)。伺服器上不需要安裝 Git 或 Python。
  資料仍由 GitHub Actions 每天產生,這支腳本只負責把最新版本搬到 IIS。

  流程:下載壓縮檔 → 解壓 → 檢查內容完整 → 只挑網站需要的檔案 → 同步到網站資料夾。
  任何一步失敗都不會動到網站資料夾,網站維持上一次的正常版本。

  注意:
  - 此檔必須以「UTF-8 含 BOM」存檔,Windows PowerShell 5.1 才不會把中文讀成亂碼。
  - 同步使用 robocopy /MIR,網站資料夾內不屬於 repo 的檔案會被刪除。
    運費試算工具(含合約價)必須放在另一個資料夾,不能放在這裡。
  - repo 必須是 Public,這支腳本才能不帶帳號下載。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\update-info.ps1
#>
param(
  [string]$SiteDir = 'D:\WebSites\info',
  [string]$WorkDir = 'D:\WebSites\_deploy',
  [string]$ZipUrl  = 'https://github.com/TEXRAY-INDUSTRIAL-CO-LTD/info-center/archive/refs/heads/main.zip'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$LogFile = Join-Path $WorkDir 'update-info.log'

# 記錄檔超過 1 MB 就換一份,避免無限長大
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
  Move-Item $LogFile "$LogFile.old" -Force
}

function Write-Log([string]$Message) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Output $line
}

try {
  # Windows Server 2016 的 PowerShell 5.1 預設可能沒啟用 TLS 1.2,而 GitHub 只接受 TLS 1.2 以上
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $zip     = Join-Path $WorkDir 'main.zip'
  $extract = Join-Path $WorkDir 'extract'
  $stage   = Join-Path $WorkDir 'stage'

  Write-Log "開始下載 $ZipUrl"
  Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120

  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  # 壓縮檔內只有一層資料夾(info-center-main)
  $root = Get-ChildItem $extract -Directory | Select-Object -First 1
  if (-not $root) { throw '壓縮檔內容不符預期,找不到專案資料夾' }

  # 先確認下載的內容完整,避免用壞掉的檔案覆蓋正常運作中的網站
  foreach ($need in 'index.html', 'web.config', 'assets', 'data\rates.json') {
    if (-not (Test-Path (Join-Path $root.FullName $need))) { throw "下載內容缺少 $need" }
  }
  $null = Get-Content (Join-Path $root.FullName 'data\rates.json') -Raw -Encoding UTF8 | ConvertFrom-Json

  # 只挑網站需要的檔案;scripts、.github、README 等不放上網站
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  New-Item -ItemType Directory -Path $stage | Out-Null
  foreach ($item in 'index.html', 'web.config', 'assets', 'data') {
    Copy-Item (Join-Path $root.FullName $item) -Destination $stage -Recurse
  }

  # /MIR 讓網站資料夾與 stage 完全一致。robocopy 的結束代碼 0~7 都是成功,8 以上才是失敗
  New-Item -ItemType Directory -Force -Path $SiteDir | Out-Null
  robocopy $stage $SiteDir /MIR /R:2 /W:5 /NP /NFL /NDL /NJH /NJS | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy 同步失敗,結束代碼 $LASTEXITCODE" }

  $rates = Get-Content (Join-Path $SiteDir 'data\rates.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Log ('完成。匯率資料日期 {0},GitHub 抓取時間 {1}' -f $rates.data_date, $rates.fetched_at)
  exit 0
}
catch {
  Write-Log "失敗,網站維持上一版:$($_.Exception.Message)"
  exit 1
}

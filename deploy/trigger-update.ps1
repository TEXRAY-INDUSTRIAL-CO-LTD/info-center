<#
.SYNOPSIS
  準時觸發 GitHub Actions「更新資料」,跑完後立刻把新資料同步到內網網站。

.DESCRIPTION
  GitHub 的 cron 排程不保證準時:2026-09 起 09:23 那輪常拖到 14:00 以後才執行。
  手動觸發(workflow_dispatch)不受排程器影響,幾秒內就會開始跑。
  所以改由這台主機的工作排程在 09:23、16:47、18:43 呼叫 GitHub API 觸發;
  workflow 裡的 cron 保留當備援,這台主機沒開時仍會有(遲到的)那一輪。

  流程:呼叫 API 觸發 → 找到這次觸發的執行 → 等它跑完 → 呼叫 update-info.ps1 同步網站。
  觸發後若等不到結果,網站仍會由每小時一次的 update-info.ps1 補上。

  權杖(fine-grained PAT,只授權 info-center 的 Actions 讀寫)存在 $TokenFile,
  由 install-trigger-task.ps1 建立並把權限限縮成只有 SYSTEM 與系統管理員可讀。

  注意:此檔必須以「UTF-8 含 BOM」存檔,Windows PowerShell 5.1 才不會把中文讀成亂碼。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\trigger-update.ps1
#>
param(
  [string]$TokenFile    = 'C:\ProgramData\TEXRAY\github-token.txt',
  [string]$WorkDir      = 'D:\WebSites\_deploy',
  [string]$UpdateScript = 'D:\WebSites\_scripts\update-info.ps1',
  [string]$Repo         = 'TEXRAY-INDUSTRIAL-CO-LTD/info-center',
  [string]$Workflow     = 'update-data.yml',
  [int]$TimeoutMinutes  = 15
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$LogFile = Join-Path $WorkDir 'trigger-update.log'

if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
  Move-Item $LogFile "$LogFile.old" -Force
}

function Write-Log([string]$Message) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Output $line
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  if (-not (Test-Path $TokenFile)) { throw "找不到權杖檔 $TokenFile,請先執行 install-trigger-task.ps1" }
  $token = (Get-Content $TokenFile -Raw).Trim()
  if (-not $token) { throw "權杖檔 $TokenFile 是空的" }

  $headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'texray-intranet-trigger'
  }
  $api = "https://api.github.com/repos/$Repo/actions/workflows/$Workflow"

  # 往前多抓 1 分鐘,容許主機時鐘與 GitHub 有些微誤差
  $since = (Get-Date).ToUniversalTime().AddMinutes(-1)

  Write-Log '觸發 GitHub Actions「更新資料」'
  try {
    Invoke-RestMethod -Method Post -Uri "$api/dispatches" -Headers $headers `
      -Body '{"ref":"main"}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60 | Out-Null
  }
  catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    switch ($code) {
      401 { throw '觸發失敗(401):權杖無效或已過期,請重新產生並執行 install-trigger-task.ps1' }
      403 { throw '觸發失敗(403):權杖沒有 Actions 寫入權限,或組織尚未核准這組權杖' }
      404 { throw '觸發失敗(404):權杖沒有授權 info-center,或 workflow 檔名已變更' }
      default { throw "觸發失敗:$($_.Exception.Message)" }
    }
  }

  # dispatches 不會回傳執行編號,改查「觸發後才建立的手動執行」
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $run = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $list = Invoke-RestMethod -Uri "$api/runs?event=workflow_dispatch&per_page=5" -Headers $headers -UseBasicParsing -TimeoutSec 60
    $run = $list.workflow_runs |
      Where-Object { ([datetime]$_.created_at).ToUniversalTime() -ge $since } |
      Select-Object -Last 1
    if ($run) { break }
  }
  if (-not $run) { throw "已觸發,但 $TimeoutMinutes 分鐘內查不到執行紀錄;網站仍會由每小時同步補上" }
  Write-Log "已開始執行 #$($run.run_number)"

  while ($run.status -ne 'completed' -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $run = Invoke-RestMethod -Uri $run.url -Headers $headers -UseBasicParsing -TimeoutSec 60
  }
  if ($run.status -ne 'completed') { throw "執行 #$($run.run_number) 超過 $TimeoutMinutes 分鐘仍未結束:$($run.html_url)" }

  # failure 也照樣同步:workflow 設計成單一來源失敗時,其餘來源的資料仍會入庫
  Write-Log "執行 #$($run.run_number) 結束,結果 $($run.conclusion)"

  # update-info.ps1 結尾會 exit,要另開程序執行,否則會連這支腳本一起結束
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpdateScript | Out-Null
  if ($LASTEXITCODE -ne 0) { throw '同步網站失敗,詳見 update-info.log' }
  Write-Log '已同步到內網網站'

  if ($run.conclusion -ne 'success') { Write-Log "注意:有來源抓取失敗,請查看 $($run.html_url)"; exit 2 }
  exit 0
}
catch {
  Write-Log "失敗:$($_.Exception.Message)"
  exit 1
}

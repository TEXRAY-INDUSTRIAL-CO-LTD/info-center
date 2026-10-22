# 部署到內網 IIS(trcom.texray.com/info/)

網址:`https://trcom.texray.com/info/`

```
GitHub Actions(每天產生資料;由伺服器準時觸發,見第四節)
        ↓  伺服器工作排程每小時一次
update-info.ps1:下載 repo 壓縮檔 → 檢查 → 同步到網站資料夾
        ↓
IIS 虛擬目錄 /info/  ← Windows 驗證(公司 AD 帳號)
```

伺服器上**不需要安裝 Git 或 Python**。前提是 repo 維持 Public。

## 存取控制:Windows 驗證

trcom.texray.com 上的 UOF 本身就是用 IIS Windows 驗證(AD 網域帳號)登入的
(`/UOF/ADAuth/` 回應 `401 Negotiate, NTLM`)。`/info/` 用同一套驗證,
**能登入 UOF 的人就能看,不需要動 UOF 的任何設定**,伺服器也不必另外安裝功能。

- 公司電腦:和開 UOF 一樣,通常會自動登入
- 公司外(手機、在家):trcom.texray.com 從網際網路也連得到(公開 IP `114.30.38.232`),
  會跳出帳密視窗,輸入 AD 帳密即可瀏覽

⚠ **運費試算工具(含合約價)**另放獨立資料夾,除了 Windows 驗證,
建議再用 IIS「URL 授權」限定特定 AD 群組。**未設定任何存取限制前,不可放上這台伺服器。**

## 一、上架網站(只做一次)

1. **建資料夾**:`D:\WebSites\info`、`D:\WebSites\_scripts`、`D:\WebSites\_deploy`(磁碟代號可依伺服器調整)。

2. **下載更新腳本**:以系統管理員身分開 PowerShell,執行:
   ```powershell
   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
   New-Item -ItemType Directory -Force D:\WebSites\_scripts | Out-Null
   Invoke-WebRequest -UseBasicParsing -OutFile D:\WebSites\_scripts\update-info.ps1 -Uri https://raw.githubusercontent.com/TEXRAY-INDUSTRIAL-CO-LTD/info-center/main/deploy/update-info.ps1
   ```
   這一步同時測試伺服器能否連到 GitHub;失敗就要請 IT 開放對外連線。
   不要用「打開檔案 → 複製文字 → 記事本另存」的方式取得,會弄丟 BOM,導致中文亂碼。

3. **第一次手動執行**:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\update-info.ps1
   ```
   最後一行出現「完成。匯率資料日期 …」即成功,`D:\WebSites\info` 會有 `assets`、`data`、`index.html`、`web.config`。

4. **新增虛擬目錄**:IIS 管理員 → 展開 `trcom.texray.com` 站台 → 右鍵「新增虛擬目錄」→ 別名 `info`、實體路徑 `D:\WebSites\info`。

5. **緊接著設定驗證**(點選 `info` → 「驗證」):
   - **Windows 驗證:啟用**
   - **匿名驗證:停用**
   - 只改 `info`,不要動上層 trcom 站台的設定
   - ⚠ 只能在 IIS 管理員設定,**不要寫進 web.config**:驗證區段在伺服器層級預設鎖定,寫在 web.config 會造成 500.19

## 二、驗證

- 公司電腦開 `https://trcom.texray.com/info/` → 和開 UOF 一樣直接進入,切換各頁資料都載入得到
- 手機用行動網路開 → 跳出帳密視窗;按取消或輸入錯誤 → **401**

## 三、自動更新

工作排程器 → 建立工作:

| 頁籤 | 設定 |
|---|---|
| 一般 | 名稱 `TEXRAY 資訊中心更新`;使用者 `SYSTEM`;勾選「以最高權限執行」 |
| 觸發程序 | 每天、開始時間 00:05;勾選「重複工作間隔 1 小時」,持續時間「無限期」 |
| 動作 | 程式 `powershell.exe`;引數 `-NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\update-info.ps1` |
| 設定 | 「如果工作已在執行,則不要啟動新的執行個體」 |

記錄檔:`D:\WebSites\_deploy\update-info.log`。任何一步失敗都不會動到網站資料夾,網站維持上一次的正常版本。

同步使用 `robocopy /MIR`,`D:\WebSites\info` 內不屬於 repo 的檔案每小時會被刪除,**不要在裡面放其他檔案**。

## 四、準時觸發資料更新

GitHub 的 cron 排程不保證準時,2026-09 起 09:23 那輪常拖到 14:00 以後才執行
(8/31~9/11 只晚幾分鐘,同一份設定之後變成晚 4.5~6.5 小時,也曾整天跳過)。
手動觸發(workflow_dispatch)不受排程器影響,所以改由這台主機準時呼叫 GitHub API:

```
工作排程 TEXRAY-InfoCenter-Trigger(週一至週五 09:23、16:47、18:43)
   └─ trigger-update.ps1:觸發「更新資料」→ 等它跑完 → 呼叫 update-info.ps1 立刻同步網站
```

workflow 裡的 cron 保留當備援:這台主機沒開或權杖過期時,仍會有遲到的那一輪,
網站也仍由每小時一次的 update-info.ps1 補上。

### 1. 產生權杖(fine-grained personal access token)

用**對 info-center 有 Write 權限**的 GitHub 帳號登入 → 右上頭像 → Settings →
Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token:

| 欄位 | 設定 |
|---|---|
| Token name | `trcom-trigger-update` |
| Resource owner | **TEXRAY-INDUSTRIAL-CO-LTD**(不是個人帳號) |
| Expiration | 依組織政策,建議 1 年;到期日記在行事曆 |
| Repository access | **Only select repositories** → `info-center` |
| Permissions → Repository | **Actions:Read and write**(Metadata: Read 會自動加上),其餘一律不開 |

產生後只會顯示一次,直接貼到下一步,**不要存成檔案、不要貼到聊天或郵件**。
若組織設定要求核准,權杖會顯示 *pending*,需組織 Owner 到
組織 Settings → Personal access tokens → Pending requests 核准後才能用。

### 2. 安裝

以系統管理員身分開 PowerShell:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://raw.githubusercontent.com/TEXRAY-INDUSTRIAL-CO-LTD/info-center/main/deploy'
Invoke-WebRequest -UseBasicParsing -OutFile D:\WebSites\_scripts\trigger-update.ps1 -Uri "$base/trigger-update.ps1"
Invoke-WebRequest -UseBasicParsing -OutFile D:\WebSites\_scripts\install-trigger-task.ps1 -Uri "$base/install-trigger-task.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\WebSites\_scripts\install-trigger-task.ps1
```
安裝腳本會:詢問權杖(不顯示)→ 先向 GitHub 驗證 → 存到 `C:\ProgramData\TEXRAY\github-token.txt`
(只有 SYSTEM 與系統管理員可讀;刻意不放在 `D:\WebSites` 底下)→ 建立工作排程 → 詢問是否試跑。

試跑後看 `D:\WebSites\_deploy\trigger-update.log`,出現「已同步到內網網站」即成功;
GitHub Actions 頁面也會多一筆 `workflow_dispatch` 的「更新資料」。

### 3. 日後維護

- **換權杖**(到期或外洩):在 GitHub 刪掉舊的、產生新的,重跑 `install-trigger-task.ps1` 即可。
- 改觸發時間:`install-trigger-task.ps1 -Times '09:23','16:47'`(會覆蓋舊排程)。
- 記錄檔結果:`已同步到內網網站` = 正常;`注意:有來源抓取失敗` = 部分來源失敗(其餘資料已更新,GitHub 會自動開 issue);
  `觸發失敗(401)` = 權杖過期;`(403)` = 權限不足或組織未核准;`(404)` = 權杖沒授權 info-center。

## 常見問題

| 症狀 | 原因與處理 |
|---|---|
| 網頁打得開,但每一頁都「載入失敗」 | `.json` MIME 沒生效。確認 `D:\WebSites\info\web.config` 存在 |
| 整個 /info/ 出現 500.19 | web.config 與伺服器設定衝突。記下錯誤畫面的「設定來源」那幾行排查 |
| 公司電腦也跳帳密視窗 | 瀏覽器沒把 trcom.texray.com 視為內部網路。開 UOF 時若也會跳,屬同一原因,請 IT 以群組原則加入「近端內部網路」 |
| /info/ 畫面怪異或被導到別處 | 上層 trcom 站台的 web.config 有全站規則(例如網址重寫)套用到子目錄 |
| 記錄檔顯示下載失敗 | 伺服器需能連 `github.com`、`codeload.github.com`(HTTPS 443) |
| 腳本中文變亂碼或語法錯誤 | `update-info.ps1` 必須是「UTF-8 含 BOM」,重新用上面的指令下載 |

# TEXRAY 綜合資訊中心

南緯實業內部用的綜合資訊平台。以「積木」方式一塊一塊擴充:匯率、紡織產業新聞、原物料價格、運費參考。

網址:https://texray-industrial-co-ltd.github.io/info-center/

---

## 目前的積木

| 積木 | 狀態 | 資料來源 | 更新 |
|---|---|---|---|
| 匯率 | ✅ 已上線 | 臺灣銀行牌告匯率(FinMind 開放 API) | 每工作日 09:23、16:47、18:43 |
| 燃油附加費資料 | ✅ 已上線(無畫面) | DHL 官網自動抓 + FedEx 人工維護 | 每工作日 09:23、16:47、18:43 |
| 紡織產業新聞 | ✅ 已上線 | Google News(多組關鍵字彙整) | 每工作日 09:23、16:47、18:43 |
| 品牌客戶動態 | ✅ 已上線 | Google News(國際成衣品牌,中英文) | 每工作日 09:23、16:47、18:43 |
| 原物料價格 | ✅ 已上線 | 新浪財經期貨日K線 + Yahoo Finance | 每工作日 09:23、16:47、18:43 |
| 運費試算 | ✅ 已上線 | DHL / FedEx 對外公告標準價目表 | 每工作日 09:23、16:47、18:43 |

## 運作方式

這是一個**純靜態網站**,沒有後端。資料由 GitHub Actions 定時抓取後 commit 成 JSON,網頁只讀自己的靜態檔:

```
GitHub Actions(每工作日 09:23、16:47、18:43)
   └─ python scripts/fetch_*.py  ──▶  data/*.json  ──▶  commit & push
                                              │
                                     GitHub Pages 靜態網頁載入
```

好處:不受瀏覽器 CORS 限制、外部服務短暫掛掉不影響瀏覽、資料自動累積成歷史。

## 目錄結構

```
index.html                  頁面骨架
assets/css/style.css        樣式(含深淺色主題與企業識別色)
assets/js/app.js            主程式:主題切換、依註冊表載入積木
assets/js/registry.js       ★ 積木註冊表
assets/js/blocks/<id>.js    各積木的畫面
assets/js/lib/              共用工具(格式化、SVG 圖表)
data/<id>.json              各積木的資料(由抓取器產生)
scripts/fetch_<id>.py       各積木的抓取器
.github/workflows/          自動更新排程
```

## 新增一塊積木

1. 寫 `scripts/fetch_<id>.py`,輸出 `data/<id>.json`
2. 寫 `assets/js/blocks/<id>.js`,`export default { render(el, data), meta(data) }`
3. 在 `assets/js/registry.js` 加一筆,`enabled: true`
4. 在 `.github/workflows/update-data.yml` 加一行 `python scripts/fetch_<id>.py`

既有積木完全不用動。

## 本機預覽

```bash
python -m http.server 8080
```

然後開 http://localhost:8080 。(不能直接雙擊 `index.html`,ES 模組與 `fetch` 需要 http 協定。)

## 手動更新資料

```bash
python scripts/fetch_rates.py
python scripts/fetch_fuel.py
```

運費公告價是**年度**資料,不在每日排程內,一年更新一次(見下方「運費試算只用公告價」):

```bash
python scripts/parse_fedex_public.py
python scripts/fetch_freight.py
```

## data/fuel.json 是什麼

一份只有兩個百分比的小檔(DHL 與 FedEx 當週燃油附加費),沒有畫面,
提供給公司內部工具取用——那些工具不放在這個 repo,
但需要一個能公開讀取的位置取得最新燃油費率。

- DHL 由 `scripts/fetch_fuel.py` 自動抓官網
- **FedEx 官網封鎖程式抓取,數值需人工維護**:改 `data/fuel_manual.json` 裡的 `percent` 與 `as_of`,
  下次排程(或手動執行)就會寫進 `data/fuel.json`

## 新聞如何過濾

只用關鍵字撈「紡織」會混進大量明星穿搭、品牌新品與同名事物
(紡織娘是昆蟲、木棉花是動漫代理商),所以標題必須**同時**符合三個條件才收錄:

1. 含**產業詞**(紡織、成衣、針織、布料、聚酯、棉花…)
2. 含**商業詞**(營收、訂單、產能、關稅、報價、研發、永續…)
3. **不含**雜訊詞(穿搭、代言、開箱、門市、房產…)

收錄後再貼上分類標籤(產業動態/個股財報/原料行情/國際貿易/技術研發/永續環保)供篩選。
規則都在 `scripts/fetch_news.py` 最上方,覺得漏了或多了直接改字串即可。

## 品牌客戶動態怎麼收

追蹤國際成衣品牌商的**經營面**消息(財報、庫存、採購、供應鏈、產能移轉),
對代工廠而言是訂單的領先指標。

- **洲別依品牌總部所在地固定歸屬**,不隨新聞事件發生地變動。
  灰色地帶已在資料檔註明:Amer Sports 總部芬蘭(安踏控股)歸歐洲、Shein 營運總部中國歸亞太。
- 查詢方式:每洲每語言把品牌名用 OR 合併成一次查詢(約 6 次請求),
  再由標題比對回推品牌;一個品牌查一次要 30 次以上,太慢。
- 過濾比產業新聞更嚴:品牌新聞九成是新品、聯名、球鞋、代言,
  標題必須含經營面詞彙才收錄。
- **英文一律用單字邊界比對**:用子字串會誤判,例如 "Glossy" 含 "loss"、
  "Finish" 含 "fin",都會被當成經營面詞彙。中文沒有詞界,維持子字串。
- 同一品牌同一天最多 3 則:財報日各家轉載會洗版(實測 Amer Sports 單日 19 則)。

## 原物料價格的資料選擇

聚酯是機能布的主要原料,但**聚酯現貨報價都在付費資料庫**(CCFGroup、隆眾等)。
改用中國期貨作為指標,聚酯鏈這條主線才補得起來:

| 群組 | 品項 | 來源 | 單位 |
|---|---|---|---|
| 聚酯鏈 | PTA、滌綸短纖、乙二醇 | 新浪財經期貨日K線 | 人民幣/噸 |
| 棉花 | 中國棉花、美棉 | 新浪 / Yahoo | 人民幣/噸、美分/磅 |
| 能源 | 布蘭特、WTI、天然氣 | Yahoo Finance | 美元/桶、美元/MMBtu |

- **一律只取日K線,不用即時報價**:新浪的即時報價與日K線在主力合約換月時
  定義不同、數字對不上(實測 PTA 即時 5,762 vs 日K線收盤 5,958),混用會讓漲跌算錯。
- 聚酯鏈與棉花另附「台幣/公斤」換算(用站上 `data/rates.json` 的台銀即期中價),
  **原油與天然氣不換算**——美元/桶換成台幣/公斤沒有意義。
- 換算值是**期貨價格換算,不等於採購報價**,頁面上有明確標註。

## 運費試算只用公告價

DHL 與 FedEx 都把標準價目表公開在官網,本站解析那些 PDF 產生 `data/freight.json`,
所以是「牌價對牌價」的公平比較。**公司議定的合約價不在此 repo,也不得放入。**

- 只做台灣**出口 / 進口**。第三地(起訖點皆非台灣)DHL 未公開價目表,
  只列 FedEx 會變成單邊報價、無法比較,故不提供。
- FedEx 官網 HTML 頁擋程式抓取,但 `content/dam/` 下的 PDF 帶 `Referer` 標頭就能下載。
- DHL 出口頁把第二張表(包裹)誤標成與第一張相同的「2.0公斤以內之文件」,
  是官方文件本身的筆誤,解析器改以表格出現順序判斷,不看標題文字。
- 中國大陸在公開手冊寫「1/2」跨兩區,分界依 DHL 合約價目表註腳:
  深圳、潮汕惠州、珠江三角洲、廣州、東莞為第 1 區,其他地區第 2 區。

### 為什麼不放進每日排程

兩家都是**年度**價目表(DHL 1/1、FedEx 1/5 生效),一年才換一次;而且 FedEx 的
Akamai 會擋 GitHub Actions 機房的 IP,在 CI 裡下載到的不是 PDF,**必須從台灣的
網路環境執行**。因此 `data/freight.json` 改為本機產生後提交。

年份集中在兩支解析腳本最上方的 `RATE_YEAR`,明年只要改這一個常數。
`.github/workflows/freight-annual-check.yml` 每月檢查一次,發現還停在去年就自動開
issue 提醒,步驟寫在 `.github/freight-annual-reminder.md`。

運費積木每天會變動的是**燃油附加費**(`data/fuel.json`),那支腳本只用標準庫、
不下載 PDF,照常留在每日排程裡。

## 注意事項

- **本 repo 為公開 repo,只放外部公開資訊。內部系統資料(Excel、ERP、資料庫)一律不得放入。**
- 匯率主要顯示「現金賣出」;台銀未掛現金牌價的幣別(如南非幣)自動改列「即期賣出」並標註。
- 台銀官網 `rate.bot.com.tw` 有反爬蟲保護、無法直接抓取,故改用 FinMind 開放 API 取得同一份牌告資料。

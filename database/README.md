# 訂單資料庫（Supabase PostgreSQL）

這個資料夾放的是把「Google Apps Script + Google Sheet」訂單改接到 Supabase 時用的建表 SQL。

目標架構：

```
網站（瀏覽器） → Supabase Edge Functions（後端，使用 service_role） → PostgreSQL
```

- 訪客（`anon`）和登入使用者（`authenticated`）**不能**直接讀寫任何訂單相關資料表。
- 所有讀寫都由 Edge Functions 處理。`service_role` key 只放在 Edge Functions 的環境變數裡，**絕對不能寫進網站前端**。

> 目前網站和 `gas/Code.gs` 都還沒改，仍然把訂單寫到 Google Sheet。這裡的 SQL 只建立資料庫結構。

---

## 檔案與執行順序

| 順序 | 檔案 | 用途 | 會不會寫入資料 |
|---|---|---|---|
| 1 | `001_create_orders.sql` | 建立 4 張資料表、取號函式、trigger、RLS 與權限，並放入目前的 13 個商品 | 會。建立結構，並寫入 13 筆商品 |
| 2 | `002_verify_orders.sql` | 查核結構與權限，並用一筆虛構訂單測試寫入和查詢 | 測試寫入全部 ROLLBACK，不留資料 |

執行方式：Supabase 後台 →「SQL Editor」→ 貼上檔案內容 →「Run」。

- `001` **只需執行一次**。整份包在 `begin; … commit;` 中，重跑會在第一個 `create table` 出現 `relation "products" already exists`，然後整批回滾，不會影響已存在的資料。
- `002` 可以重複執行。

---

## 資料表

| 資料表 | 對應原本的 | 說明 |
|---|---|---|
| `orders` | Sheet「訂單」 | 一筆訂單一列 |
| `order_items` | Sheet「訂單明細」 | 一個品項一列，用 `order_id` 連到 `orders.id` |
| `products` | `gas/Code.gs` 的 `PRICE_LIST` | 價目表，下單時由後端讀取計價 |
| `order_daily_counters` | Script Properties 的 `seq_yyyyMMdd` | 每日訂單流水號，只給 `next_order_no()` 用 |

### `orders` 欄位對照

| 欄位 | 型別 | 原 Sheet 欄 | 來源 |
|---|---|---|---|
| `id` | `uuid`，主鍵 | 無 | **新增**，內部主鍵 |
| `order_no` | `text`，unique | A 訂單編號 | 原專案，格式 `GC20261118-0001` 不變 |
| `status` | `text`，預設 `已收到` | C 狀態 | 原專案有狀態欄；五種值是這次確認的 |
| `pickup_method` | `text` | D 取餐方式 | 原專案：外帶 / 內用 / 宅配 |
| `customer_name` | `text`（1–50 字） | E 姓名 | 原專案 |
| `customer_phone` | `text`（8–20 字） | F 電話 | 原專案，保留客人輸入的原樣 |
| `phone_digits` | `text`，自動產生 | 無 | **新增**，只含數字，供查詢比對 |
| `customer_email` | `text`，可空 | G Email | 原專案（原本存空字串，這裡改存 `NULL`） |
| `shipping_address` | `text`，可空 | H 宅配地址 | 原專案（原本非宅配存空字串，這裡改存 `NULL`） |
| `note` | `text`，可空（≤300 字） | L 備註 | 原專案 |
| `items_summary` | `text` | I 品項摘要 | 原專案，例如 `招牌鮮肉鍋貼 x2、酸辣湯 x1` |
| `item_count` | `integer` | J 數量合計 | 原專案 |
| `total_amount` | `integer`（NT$） | K 訂單金額 | 原專案 |
| `created_at` | `timestamptz` | B 建立時間 | 原專案；**這次改成含時區** |
| `updated_at` | `timestamptz` | M 更新時間 | 這次新增（只有狀態改變時才更新） |

### `order_items` 欄位對照

| 欄位 | 型別 | 原 Sheet 欄 | 來源 |
|---|---|---|---|
| `id` | `bigint` identity，主鍵 | 無 | **新增** |
| `order_id` | `uuid`，外鍵 → `orders.id` | A 訂單編號 | 原專案用編號關聯；**這次改用外鍵** |
| `product_code` | `text`，外鍵 → `products.code` | B 品項代碼 | 原專案 |
| `product_name` | `text` | C 品名 | 原專案，下單當下的快照 |
| `unit_price` | `integer` | D 單價 | 原專案，下單當下的快照 |
| `quantity` | `integer`（1–99） | E 數量 | 原專案 |
| `subtotal` | `integer`，自動計算 | F 小計 | 原專案，改為 `unit_price * quantity` 自動算 |
| `created_at` | `timestamptz` | 無 | **新增** |

---

## 哪些設計來自原專案、哪些是這次新增

**沿用原專案（`gas/Code.gs`、`index.html`）**
- 訂單編號格式：`GC` + 台北日期 + 當日 4 位流水號。
- 金額以伺服器端價目表為準，前端送來的金額不採用。
- 一筆訂單分成主表和明細，明細保存下單當下的品名和單價。
- 欄位長度與格式限制：姓名 ≤50、電話 8–20 字（數字、`+`、`()`、`-`、空白）、Email ≤100、地址 ≤200、備註 ≤300、數量 1–99。
- 取餐方式只能是外帶、內用、宅配；只有宅配需要地址。
- 13 個商品的代碼、名稱和價格。
- 「更新時間」只在狀態改變時更新，和 `onEdit` 的行為一樣。

**這次新增或改變**
- `products` 資料表，取代寫死在程式裡的 `PRICE_LIST`，商品下架用 `is_active = false`，不刪除。
- `order_daily_counters` 加上 `next_order_no()`，用資料庫鎖避免同時下單時重號。單日超過 9999 筆會報錯，原程式在這種情況會讓編號重複。
- 狀態固定為五種：已收到、製作中、可取餐、已完成、已取消。原 HEAD 版本的「新訂單」「已確認」不被接受。
- `phone_digits`：把 `0912-345-678` 和 `0912345678` 視為同一支電話。
- 外鍵：明細一定要對應到存在的訂單和商品；同一訂單同一商品只能有一列。
- 時間改用 `timestamptz`（含時區），訂單編號的日期用 `Asia/Taipei` 計算。
- 權限：四張表都啟用 RLS 且**沒有任何 policy**；`anon`、`authenticated` 的權限全部收回。
- `service_role` 只拿到需要的權限：

  | 資料表 | 權限 |
  |---|---|
  | `products` | SELECT |
  | `orders` | SELECT、INSERT、UPDATE（**只限 `status` 欄**） |
  | `order_items` | SELECT、INSERT |
  | `order_daily_counters` | 無，只能透過 `next_order_no()` |

  所有表都不給 DELETE、TRUNCATE。

**原專案有、這裡沒有搬過來**
- 防止試算表公式注入（開頭加 `'`）：資料庫不會執行公式，不需要。
- 防機器人欄位 `website`：屬於 Edge Function 的工作，不存進資料庫。
- 寄通知信：見下方「尚未完成」。

---

## 每一步預期看到的結果

### 執行 `001_create_orders.sql`
- 顯示 `Success. No rows returned`。
- Table Editor 出現 `products`、`order_daily_counters`、`orders`、`order_items`，`products` 有 13 筆。
- Supabase 可能提示「RLS enabled, no policies」。**這是刻意的**：沒有 policy 代表訪客讀不到任何資料。

### 執行 `002_verify_orders.sql`

第一部分是唯讀查核。SQL Editor 只會顯示最後一段查詢的結果，所以建議**一次選取一段 A1–A8 執行**：

| 查核 | 預期結果 |
|---|---|
| A1 | 4 列，`rls_enabled` 全為 `true` |
| A2 | `policy_count = 0` |
| A3 | `anon`、`authenticated` 全部 `false`；`service_role` 的權限與上表相符；所有 `can_delete`、`can_truncate` 為 `false` |
| A4 | 只有 `service_role` 的 `status` 為 `true` |
| A5 | 只有 `service_role` 為 `true` |
| A6 | `orders` 15 欄、`order_items` 8 欄；`order_no` 預設 `next_order_no()`；`phone_digits`、`subtotal` 為 `ALWAYS` |
| A7 | 主鍵、外鍵、unique、check 條件列表 |
| A8 | 2 個 trigger；13 個商品，全部 `is_active = true` |

第二部分（B1–B4）要**從 `begin;` 選到檔案最後一起執行**：

- 訊息（Notices）會出現一連串 `PASS …`，共 27 項。包含：訂單編號、計價、查詢、狀態更新，以及各種應該被擋下的操作。
- B3 會顯示虛構訂單 `GC20991231-0001`：狀態「製作中」、合計 245、明細 2 列。
- B4 在 ROLLBACK 之後執行，預期 `leftover_orders = 0`、`leftover_counters = 0`。

只要出現 `FAIL …` 或任何錯誤，交易就會中止，同樣不會留下資料。如果看到 `permission denied to set role`，代表目前帳號不能切換角色，請改用 Supabase 專案擁有者的 SQL Editor 執行。

### 已做過的本機測試
兩個檔案都已在本機的 PGlite（以 WebAssembly 執行的 PostgreSQL 16）跑過：
- `001` 成功；重跑時會報 `already exists` 並回滾。
- `002` 的 27 項 PASS 全部通過，ROLLBACK 後沒有殘留資料。

這個環境沒有連到 Supabase。`anon`、`authenticated`、`service_role` 三個角色和預設權限都是手動模擬的，所以在 Supabase 上仍要執行一次 `002` 確認。

---

## 這次尚未完成的串接工作

1. **Edge Function：建立訂單**。需要做的事：
   - 驗證欄位，並檢查防機器人欄位 `website`。
   - 從 `products` 讀取價格，只接受 `is_active = true` 的品項。
   - 計算金額、`items_summary` 和 `item_count`。
   - 寫入 `orders` 和 `order_items`，再回傳 `{ ok, orderId, total }`。

   空字串要轉成 `NULL`，非宅配時地址要存 `NULL`。

   ⚠️ 目前寫入主表和寫入明細是兩次寫入。如果用 supabase-js 分兩次 insert，第二次失敗時會留下沒有明細的訂單。建議之後再加一個資料庫函式，例如 `create_order()`，在同一個交易中完成兩次寫入。這次沒有建立這個函式。
2. **Edge Function：查詢訂單**。用 `order_no` 加上 `phone_digits` 查詢，只回傳品項、金額、狀態、更新時間，不回傳姓名、電話、地址。
3. **CORS 與頻率限制**：Edge Functions 要允許網站網域，並限制查詢次數，避免有人猜訂單編號。
4. **網站前端**：
   - `index.html` 的 `ORDER_ENDPOINT` 和 `orders.html` 的查詢網址要改指向 Edge Functions。
   - 前端 `products` 陣列仍然寫死，改價時要同時改 `products` 資料表，否則畫面顯示的價格和實際收費會不一致。
5. **店家改狀態的方式**：目前只能在 Supabase 後台 Table Editor 或 SQL Editor 修改 `orders.status`，`updated_at` 會自動更新。還沒有店家管理頁面，也沒有登入機制。
6. **通知信**：原本用 Apps Script 的 MailApp，但 `NOTIFY_EMAIL` 是空的，店家其實沒收到通知。Supabase 端還沒有替代方案。
7. **Google Sheet 舊訂單搬移**：沒有做。如果要搬：
   - 「新訂單」和「已確認」要先改成「已收到」，否則會違反狀態限制。
   - 空字串的 Email 和地址要轉成 `NULL`。
   - 搬完要把 `order_daily_counters` 調到各日期已用的最大流水號，否則新訂單會撞號。
8. **Google 上實際部署的 Apps Script 版本**：repo 看不出來，待確認。這會影響舊資料有哪些狀態值、有沒有「更新時間」欄。

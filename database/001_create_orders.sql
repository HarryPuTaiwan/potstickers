-- =====================================================================
-- 鍋淬 GUOCUI 訂單資料表（Supabase PostgreSQL）
-- 001_create_orders.sql
--
-- 只需執行一次。整份包在一個交易中：
--   * 成功：全部建立。
--   * 任何一步失敗（例如資料表已存在）：整批回滾，不影響既有資料。
-- 本檔不含 DROP / TRUNCATE / DELETE。
--
-- 存取模型：只有後端（Supabase Edge Functions，使用 service_role）可讀寫。
-- anon / authenticated 角色沒有任何資料表權限，也不建立任何 RLS policy。
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. 商品價目表（取代 Apps Script 的 PRICE_LIST，下單時由後端讀取計價）
-- ---------------------------------------------------------------------
create table public.products (
  code        text        primary key
                          check (code ~ '^[a-z0-9_]{1,30}$'),
  name        text        not null
                          check (char_length(btrim(name)) between 1 and 100),
  price       integer     not null
                          check (price >= 0),                 -- NT$ 整數
  is_active   boolean     not null default true,              -- 下架改 false，不刪除
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  public.products        is '商品價目表。下單金額以此為準（原 Apps Script PRICE_LIST）。';
comment on column public.products.code   is '品項代碼，對應網站 products[].id，例如 p1、gift';
comment on column public.products.price  is '單價，新台幣整數';

-- 現有 13 個品項（來源：gas/Code.gs PRICE_LIST，與 index.html products 相同）
insert into public.products (code, name, price) values
  ('p1',   '招牌鮮肉鍋貼',            95),
  ('p2',   '韭香鮮肉鍋貼',           100),
  ('p3',   '椒麻香辣鍋貼',           110),
  ('p4',   '鮮蔬菇香鍋貼',            95),
  ('p5',   '經典高麗菜水餃',          90),
  ('p6',   '鮮蝦手工水餃',           135),
  ('p7',   '酸辣湯',                  55),
  ('p8',   '暖心玉米濃湯',            50),
  ('p9',   '冷泡烏龍茶',              45),
  ('p10',  '黃金泡菜',                55),
  ('p11',  '涼拌小黃瓜',              45),
  ('p12',  '滷香豆干',                50),
  ('gift', '招牌招財鍋貼禮盒 50 入', 680);

-- ---------------------------------------------------------------------
-- 2. 每日訂單流水號（取代 Apps Script 的 Script Properties seq_yyyyMMdd）
-- ---------------------------------------------------------------------
create table public.order_daily_counters (
  order_date  date        primary key,                        -- Asia/Taipei 日期
  last_seq    integer     not null default 0
                          check (last_seq between 0 and 9999), -- 編號只有 4 位
  updated_at  timestamptz not null default now()
);

comment on table public.order_daily_counters is '每日訂單流水號計數，只供 next_order_no() 使用。';

-- 產生訂單編號：GC + 台北日期 + 當日 4 位流水號，例如 GC20261118-0001
-- INSERT ... ON CONFLICT DO UPDATE 會鎖住當日那一列，同時下單也不會重號。
create or replace function public.next_order_no(p_at timestamptz default now())
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date := (p_at at time zone 'Asia/Taipei')::date;
  v_seq integer;
begin
  insert into public.order_daily_counters as c (order_date, last_seq)
  values (v_day, 1)
  on conflict (order_date)
  do update set last_seq = c.last_seq + 1, updated_at = now()
  returning c.last_seq into v_seq;

  return 'GC' || to_char(v_day, 'YYYYMMDD') || '-' || lpad(v_seq::text, 4, '0');
end;
$$;

comment on function public.next_order_no(timestamptz) is
  '產生訂單編號 GC+yyyyMMdd(Asia/Taipei)+-+4 位流水號。單日超過 9999 筆會報錯。';

-- ---------------------------------------------------------------------
-- 3. 訂單主表（原 Sheet「訂單」）
-- ---------------------------------------------------------------------
create table public.orders (
  id               uuid        primary key default gen_random_uuid(),
  order_no         text        not null unique
                               default public.next_order_no()
                               check (order_no ~ '^GC[0-9]{8}-[0-9]{4}$'),
  status           text        not null default '已收到'
                               check (status in ('已收到', '製作中', '可取餐', '已完成', '已取消')),
  pickup_method    text        not null
                               check (pickup_method in ('外帶', '內用', '宅配')),
  customer_name    text        not null
                               check (char_length(btrim(customer_name)) between 1 and 50),
  customer_phone   text        not null
                               check (customer_phone ~ '^[0-9+() -]{8,20}$'),
  phone_digits     text        generated always as (regexp_replace(customer_phone, '[^0-9]', '', 'g')) stored,
  customer_email   text
                               check (customer_email is null
                                      or (char_length(customer_email) <= 100
                                          and customer_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  shipping_address text
                               check (shipping_address is null
                                      or char_length(shipping_address) <= 200),
  note             text
                               check (note is null or char_length(note) <= 300),
  items_summary    text        not null
                               check (char_length(items_summary) > 0),
  item_count       integer     not null
                               check (item_count >= 1),
  total_amount     integer     not null
                               check (total_amount >= 0),       -- NT$ 整數
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),          -- 狀態最後變更時間

  -- 宅配必須有地址；非宅配不存地址（與 Apps Script validate_ 相同）
  constraint orders_shipping_address_by_method check (
    (pickup_method = '宅配' and shipping_address is not null and char_length(btrim(shipping_address)) > 0)
    or (pickup_method <> '宅配' and shipping_address is null)
  )
);

create index orders_created_at_idx on public.orders (created_at desc);
create index orders_status_idx     on public.orders (status);

comment on table  public.orders                is '訂單主表（原 Google Sheet「訂單」）。';
comment on column public.orders.order_no       is '對外訂單編號，客人查詢用，例如 GC20261118-0001';
comment on column public.orders.phone_digits   is '電話只保留數字，查詢比對用（自動產生）';
comment on column public.orders.items_summary  is '品項摘要，例如「招牌鮮肉鍋貼 x2、酸辣湯 x1」，由後端寫入';
comment on column public.orders.item_count     is '數量合計，由後端寫入';
comment on column public.orders.total_amount   is '訂單金額，由後端依 products.price 計算';
comment on column public.orders.updated_at     is '狀態最後變更時間；status 改變時由 trigger 自動更新';

-- ---------------------------------------------------------------------
-- 4. 訂單明細（原 Sheet「訂單明細」，一個品項一列）
-- ---------------------------------------------------------------------
create table public.order_items (
  id            bigint      generated always as identity primary key,
  order_id      uuid        not null references public.orders (id),       -- 預設 RESTRICT：不會連帶刪除
  product_code  text        not null references public.products (code),
  product_name  text        not null,                                     -- 下單當下品名快照
  unit_price    integer     not null check (unit_price >= 0),             -- 下單當下單價快照
  quantity      integer     not null check (quantity between 1 and 99),
  subtotal      integer     generated always as (unit_price * quantity) stored,
  created_at    timestamptz not null default now(),

  constraint order_items_order_product_unique unique (order_id, product_code)
);

comment on table  public.order_items              is '訂單明細（原 Google Sheet「訂單明細」）。';
comment on column public.order_items.product_name is '下單當下品名快照，之後改商品名稱不影響舊訂單';
comment on column public.order_items.unit_price   is '下單當下單價快照，之後改價不影響舊訂單';

-- ---------------------------------------------------------------------
-- 5. updated_at 自動更新
-- ---------------------------------------------------------------------
-- 訂單：只有 status 改變時才更新（與 Apps Script onEdit 的行為相同）
create or replace function public.orders_touch_status_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger orders_status_updated_at
  before update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.orders_touch_status_updated_at();

-- 商品：任何欄位改變都更新
create or replace function public.products_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger products_updated_at
  before update on public.products
  for each row
  execute function public.products_touch_updated_at();

-- ---------------------------------------------------------------------
-- 6. RLS：四張表全部啟用，且「不建立任何 policy」
--    => anon / authenticated 即使有權限也讀不到任何列；
--       service_role 具 BYPASSRLS，由 Edge Functions 使用。
-- ---------------------------------------------------------------------
alter table public.products             enable row level security;
alter table public.order_daily_counters enable row level security;
alter table public.orders               enable row level security;
alter table public.order_items          enable row level security;

-- ---------------------------------------------------------------------
-- 7. 資料表權限：先全部收回，再只給後端需要的
--    （Supabase 預設會把 public schema 新表的權限給 anon / authenticated）
-- ---------------------------------------------------------------------
revoke all on table public.products, public.order_daily_counters, public.orders, public.order_items
  from public, anon, authenticated, service_role;

-- 後端（service_role）：
--   products     ：只讀（價目由管理者在 SQL Editor / Table Editor 維護）
--   orders       ：讀、新增；UPDATE 只限 status 欄（updated_at 由 trigger 寫入）；
--                  不給 DELETE / TRUNCATE
--   order_items  ：讀、新增；不給 UPDATE / DELETE / TRUNCATE
--   order_daily_counters：不直接存取，只透過 next_order_no()
grant select                 on table public.products    to service_role;
grant select, insert         on table public.orders      to service_role;
grant update (status)        on table public.orders      to service_role;
grant select, insert         on table public.order_items to service_role;

-- 函式權限：只有後端可以呼叫取號函式；trigger 函式不對外開放
revoke all on function public.next_order_no(timestamptz)          from public, anon, authenticated;
revoke all on function public.orders_touch_status_updated_at()    from public, anon, authenticated;
revoke all on function public.products_touch_updated_at()         from public, anon, authenticated;
grant execute on function public.next_order_no(timestamptz) to service_role;

commit;

-- =====================================================================
-- 鍋淬 GUOCUI 訂單資料表查核
-- 002_verify_orders.sql（在 001_create_orders.sql 成功後執行）
--
-- 第一部分（A1–A8）：唯讀查詢，只看結構與權限，不寫入任何資料。
-- 第二部分（B）：在「一個交易」內用虛構訂單測試寫入、查詢、限制與權限，
--               最後 ROLLBACK，不留下任何資料。
--   * 虛構訂單日期用 2099-12-31，不會碰到今天真實訂單的流水號。
--   * 任何檢查失敗會 RAISE EXCEPTION，交易中止，同樣不會留下資料。
--   * 本檔不含 DELETE / TRUNCATE / DROP，不動既有訂單。
-- =====================================================================


-- =====================================================================
-- 第一部分：唯讀查核
-- =====================================================================

-- A1. 四張表都存在，且 RLS 已啟用
--     預期：4 列，rls_enabled 全為 true
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('products', 'order_daily_counters', 'orders', 'order_items')
order by c.relname;

-- A2. 沒有任何 RLS policy（不開放給訪客）
--     預期：policy_count = 0
select count(*) as policy_count
from pg_policies
where schemaname = 'public'
  and tablename in ('products', 'order_daily_counters', 'orders', 'order_items');

-- A3. 各角色的資料表權限
--     預期：anon、authenticated 全部 false
--           service_role：products 只有 select；orders、order_items 有 select、insert；
--                         order_daily_counters 全部 false；所有表 delete、truncate 都是 false
select r.role, t.tbl as table_name,
       has_table_privilege(r.role, t.tbl, 'SELECT')   as can_select,
       has_table_privilege(r.role, t.tbl, 'INSERT')   as can_insert,
       has_table_privilege(r.role, t.tbl, 'UPDATE')   as can_update_all_columns,
       has_table_privilege(r.role, t.tbl, 'DELETE')   as can_delete,
       has_table_privilege(r.role, t.tbl, 'TRUNCATE') as can_truncate
from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
cross join (values ('public.products'), ('public.order_daily_counters'),
                   ('public.orders'), ('public.order_items')) as t(tbl)
order by r.role, t.tbl;

-- A4. orders 欄位層級 UPDATE 權限
--     預期：只有 service_role 的 status 為 true
select r.role, c.col,
       has_column_privilege(r.role, 'public.orders', c.col, 'UPDATE') as can_update
from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
cross join (values ('status'), ('total_amount'), ('customer_phone'), ('order_no')) as c(col)
order by r.role, c.col;

-- A5. 取號函式的執行權限
--     預期：只有 service_role 為 true
select r.role,
       has_function_privilege(r.role, 'public.next_order_no(timestamptz)', 'EXECUTE') as can_execute
from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
order by r.role;

-- A6. orders 與 order_items 欄位、型別、預設值
--     預期：orders 15 欄、order_items 8 欄；
--           order_no 預設 next_order_no()；phone_digits、subtotal 為 generated（ALWAYS）
select table_name, ordinal_position, column_name, data_type, is_nullable,
       column_default, is_generated
from information_schema.columns
where table_schema = 'public' and table_name in ('orders', 'order_items')
order by table_name, ordinal_position;

-- A7. 限制條件（主鍵、外鍵、唯一、check）
select conrelid::regclass as table_name, conname, contype, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid in ('public.products'::regclass, 'public.order_daily_counters'::regclass,
                   'public.orders'::regclass, 'public.order_items'::regclass)
order by conrelid::regclass::text, contype, conname;

-- A8. Trigger 與商品資料
--     預期：orders_status_updated_at、products_updated_at 兩個 trigger；
--           products 13 筆，全部 is_active = true
select tgrelid::regclass as table_name, tgname
from pg_trigger
where not tgisinternal
  and tgrelid in ('public.orders'::regclass, 'public.products'::regclass)
order by tgname;

select code, name, price, is_active
from public.products
order by case when code = 'gift' then 999 else substring(code from 2)::int end;


-- =====================================================================
-- 第二部分：虛構訂單寫入測試（全部在交易內，最後 ROLLBACK）
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- B1. 以後端角色 service_role 測試（Edge Functions 使用的角色）
-- ---------------------------------------------------------------------
set local role service_role;

do $$
declare
  v_id      uuid;
  v_no      text;
  v_no2     text;
  v_total   integer;
  v_count   integer;
  v_summary text;
  v_upd     timestamptz;
  v_n       integer;
  v_digits  text;
begin
  -- 1) 訂單編號：格式、遞增、以台北時間換日
  v_no := public.next_order_no('2099-12-31 12:00:00+08');
  if v_no !~ '^GC20991231-[0-9]{4}$' then
    raise exception 'FAIL B1-1 訂單編號格式不符：%', v_no;
  end if;
  v_no2 := public.next_order_no('2099-12-31 23:59:00+08');
  if right(v_no2, 4)::int <> right(v_no, 4)::int + 1 then
    raise exception 'FAIL B1-1 流水號沒有遞增：% → %', v_no, v_no2;
  end if;
  -- UTC 2099-12-31 16:30 = 台北 2100-01-01 00:30，應算到 2100-01-01
  if public.next_order_no('2099-12-31 16:30:00+00') !~ '^GC21000101-' then
    raise exception 'FAIL B1-1 訂單編號沒有以 Asia/Taipei 換日';
  end if;
  raise notice 'PASS B1-1 訂單編號 %、%，並以台北時間換日', v_no, v_no2;

  -- 2) 依 products 計價後寫入一筆多品項訂單（招牌鮮肉鍋貼 x2、酸辣湯 x1）
  select sum(p.price * q.qty), sum(q.qty),
         string_agg(p.name || ' x' || q.qty, '、' order by q.ord)
    into v_total, v_count, v_summary
  from (values ('p1', 2, 1), ('p7', 1, 2)) as q(code, qty, ord)
  join public.products p on p.code = q.code;

  insert into public.orders
    (order_no, pickup_method, customer_name, customer_phone, items_summary,
     item_count, total_amount, created_at, updated_at)
  values
    (v_no, '外帶', '測試顧客（虛構）', '0912-345-678', v_summary,
     v_count, v_total, '2099-12-31 12:00:00+08', '2099-12-31 12:00:00+08')
  returning id, phone_digits into v_id, v_digits;

  insert into public.order_items (order_id, product_code, product_name, unit_price, quantity)
  select v_id, p.code, p.name, p.price, q.qty
  from (values ('p1', 2), ('p7', 1)) as q(code, qty)
  join public.products p on p.code = q.code;

  if v_total <> 245 or v_count <> 3 then
    raise exception 'FAIL B1-2 金額或數量不符：total=% count=%', v_total, v_count;
  end if;
  select sum(subtotal) into v_n from public.order_items where order_id = v_id;
  if v_n <> v_total then
    raise exception 'FAIL B1-2 明細小計加總 % 不等於訂單金額 %', v_n, v_total;
  end if;
  if v_digits <> '0912345678' then
    raise exception 'FAIL B1-2 phone_digits 不符：%', v_digits;
  end if;
  raise notice 'PASS B1-2 寫入訂單 %：%，合計 NT$ %，明細 2 列', v_no, v_summary, v_total;

  -- 3) 查詢：訂單編號 + 電話（不同寫法都要查得到；電話錯查不到）
  select count(*) into v_n from public.orders
  where order_no = v_no and phone_digits = regexp_replace('0912 345 678', '[^0-9]', '', 'g');
  if v_n <> 1 then raise exception 'FAIL B1-3 正確電話查不到訂單'; end if;
  select count(*) into v_n from public.orders
  where order_no = v_no and phone_digits = '0999999999';
  if v_n <> 0 then raise exception 'FAIL B1-3 錯誤電話仍查到訂單'; end if;
  raise notice 'PASS B1-3 編號+電話查詢正確';

  -- 4) 改狀態：updated_at 自動更新
  update public.orders set status = '製作中' where id = v_id returning updated_at into v_upd;
  if v_upd <> now() then
    raise exception 'FAIL B1-4 改狀態後 updated_at 沒有更新：%', v_upd;
  end if;
  raise notice 'PASS B1-4 狀態改為「製作中」，updated_at 自動更新為 %', v_upd;

  -- 5) 應該被擋下的操作
  begin
    update public.orders set status = '新訂單' where id = v_id;
    raise exception 'FAIL B1-5 接受了不存在的狀態「新訂單」';
  exception when check_violation then
    raise notice 'PASS B1-5a 拒絕不存在的狀態';
  end;

  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               items_summary, item_count, total_amount)
    values ('GC20991231-9001', '宅配', '測試', '0912345678', 'x', 1, 0);
    raise exception 'FAIL B1-5 宅配沒有地址仍可寫入';
  exception when check_violation then
    raise notice 'PASS B1-5b 宅配必須填地址';
  end;

  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               shipping_address, items_summary, item_count, total_amount)
    values ('GC20991231-9002', '外帶', '測試', '0912345678', '台北市', 'x', 1, 0);
    raise exception 'FAIL B1-5 非宅配卻存了地址';
  exception when check_violation then
    raise notice 'PASS B1-5c 非宅配不存地址';
  end;

  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               items_summary, item_count, total_amount)
    values ('GC20991231-9003', '外帶', '測試', '0912345678', 'x', 1, -1);
    raise exception 'FAIL B1-5 接受了負數金額';
  exception when check_violation then
    raise notice 'PASS B1-5d 拒絕負數金額';
  end;

  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               items_summary, item_count, total_amount)
    values ('GC20991231-9004', '外帶', '測試', 'abc', 'x', 1, 0);
    raise exception 'FAIL B1-5 接受了錯誤電話格式';
  exception when check_violation then
    raise notice 'PASS B1-5e 拒絕錯誤電話格式';
  end;

  begin
    insert into public.order_items (order_id, product_code, product_name, unit_price, quantity)
    values (v_id, 'p2', '韭香鮮肉鍋貼', 100, 0);
    raise exception 'FAIL B1-5 接受了數量 0';
  exception when check_violation then
    raise notice 'PASS B1-5f 數量必須 1–99';
  end;

  begin
    insert into public.order_items (order_id, product_code, product_name, unit_price, quantity)
    values (v_id, 'p1', '招牌鮮肉鍋貼', 95, 1);
    raise exception 'FAIL B1-5 同一訂單重複品項';
  exception when unique_violation then
    raise notice 'PASS B1-5g 同一訂單同一品項只能一列';
  end;

  begin
    insert into public.order_items (order_id, product_code, product_name, unit_price, quantity)
    values (v_id, 'p999', '不存在', 1, 1);
    raise exception 'FAIL B1-5 接受了不存在的品項代碼';
  exception when foreign_key_violation then
    raise notice 'PASS B1-5h 品項代碼必須存在於 products';
  end;

  -- 6) service_role 也不能做的事
  begin
    update public.orders set total_amount = 1 where id = v_id;
    raise exception 'FAIL B1-6 後端可以改訂單金額';
  exception when insufficient_privilege then
    raise notice 'PASS B1-6a 後端只能改 status，不能改金額';
  end;

  begin
    delete from public.orders where id = v_id;
    raise exception 'FAIL B1-6 後端可以刪除訂單';
  exception when insufficient_privilege then
    raise notice 'PASS B1-6b 後端不能刪除訂單';
  end;

  begin
    update public.order_items set quantity = 5 where order_id = v_id;
    raise exception 'FAIL B1-6 後端可以修改訂單明細';
  exception when insufficient_privilege then
    raise notice 'PASS B1-6c 後端不能修改訂單明細';
  end;

  begin
    update public.products set price = 1 where code = 'p1';
    raise exception 'FAIL B1-6 後端可以改價';
  exception when insufficient_privilege then
    raise notice 'PASS B1-6d 後端不能改價目表';
  end;

  begin
    perform 1 from public.order_daily_counters;
    raise exception 'FAIL B1-6 後端可以直接讀流水號表';
  exception when insufficient_privilege then
    raise notice 'PASS B1-6e 流水號表只能透過 next_order_no()';
  end;
end
$$;

reset role;

-- ---------------------------------------------------------------------
-- B2. 訪客角色 anon、登入使用者 authenticated：完全不能存取
-- ---------------------------------------------------------------------
set local role anon;

do $$
begin
  begin
    perform 1 from public.orders limit 1;
    raise exception 'FAIL B2 % 可以讀 orders', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 orders', current_user;
  end;
  begin
    perform 1 from public.order_items limit 1;
    raise exception 'FAIL B2 % 可以讀 order_items', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 order_items', current_user;
  end;
  begin
    perform 1 from public.products limit 1;
    raise exception 'FAIL B2 % 可以讀 products', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 products', current_user;
  end;
  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               items_summary, item_count, total_amount)
    values ('GC20991231-9100', '外帶', '測試', '0912345678', 'x', 1, 0);
    raise exception 'FAIL B2 % 可以新增訂單', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能新增訂單', current_user;
  end;
  begin
    perform public.next_order_no('2099-12-31 12:00:00+08');
    raise exception 'FAIL B2 % 可以呼叫 next_order_no', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能呼叫 next_order_no', current_user;
  end;
end
$$;

reset role;
set local role authenticated;

do $$
begin
  begin
    perform 1 from public.orders limit 1;
    raise exception 'FAIL B2 % 可以讀 orders', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 orders', current_user;
  end;
  begin
    perform 1 from public.order_items limit 1;
    raise exception 'FAIL B2 % 可以讀 order_items', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 order_items', current_user;
  end;
  begin
    perform 1 from public.products limit 1;
    raise exception 'FAIL B2 % 可以讀 products', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能讀 products', current_user;
  end;
  begin
    insert into public.orders (order_no, pickup_method, customer_name, customer_phone,
                               items_summary, item_count, total_amount)
    values ('GC20991231-9101', '外帶', '測試', '0912345678', 'x', 1, 0);
    raise exception 'FAIL B2 % 可以新增訂單', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能新增訂單', current_user;
  end;
  begin
    perform public.next_order_no('2099-12-31 12:00:00+08');
    raise exception 'FAIL B2 % 可以呼叫 next_order_no', current_user;
  exception when insufficient_privilege then
    raise notice 'PASS B2 % 不能呼叫 next_order_no', current_user;
  end;
end
$$;

reset role;

-- ---------------------------------------------------------------------
-- B3. 查看虛構訂單（ROLLBACK 前最後一眼）
--     預期：1 筆訂單 GC20991231-xxxx、狀態「製作中」、合計 245，明細 2 列
-- ---------------------------------------------------------------------
select o.order_no, o.status, o.pickup_method, o.customer_phone, o.phone_digits,
       o.items_summary, o.item_count, o.total_amount,
       i.product_code, i.product_name, i.unit_price, i.quantity, i.subtotal,
       o.created_at at time zone 'Asia/Taipei' as created_at_taipei,
       o.updated_at
from public.orders o
join public.order_items i on i.order_id = o.id
where o.order_no like 'GC20991231-%'
order by i.product_code;

-- 撤銷本交易的所有寫入（包含虛構訂單與 2099/2100 的流水號）
rollback;

-- B4. 確認沒有留下虛構資料
--     預期：leftover_orders = 0、leftover_counters = 0
select
  (select count(*) from public.orders where order_no like 'GC2099%' or order_no like 'GC2100%') as leftover_orders,
  (select count(*) from public.order_daily_counters where order_date >= '2099-01-01')          as leftover_counters;

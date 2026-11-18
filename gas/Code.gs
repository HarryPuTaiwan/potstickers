/**
 * 鍋淬 GUOCUI 線上訂單接收程式（Google Apps Script Web App）
 * 部署方式請見 gas/README.md
 */

// ===== 設定 =====
const CONFIG = {
  ORDER_SHEET: '訂單',
  ITEM_SHEET: '訂單明細',
  NOTIFY_EMAIL: '',          // 新訂單通知信收件者，留空則不寄
  SEND_CUSTOMER_EMAIL: true, // 顧客有填 Email 時寄確認信
  ORDER_PREFIX: 'GC',
  TIMEZONE: 'Asia/Taipei',
};

// 價格以伺服器為準，避免前端被竄改。新增或改價時，這裡要和網站 products 一起改。
const PRICE_LIST = {
  p1: { name: '招牌鮮肉鍋貼', price: 95 },
  p2: { name: '韭香鮮肉鍋貼', price: 100 },
  p3: { name: '椒麻香辣鍋貼', price: 110 },
  p4: { name: '鮮蔬菇香鍋貼', price: 95 },
  p5: { name: '經典高麗菜水餃', price: 90 },
  p6: { name: '鮮蝦手工水餃', price: 135 },
  p7: { name: '酸辣湯', price: 55 },
  p8: { name: '暖心玉米濃湯', price: 50 },
  p9: { name: '冷泡烏龍茶', price: 45 },
  p10: { name: '黃金泡菜', price: 55 },
  p11: { name: '涼拌小黃瓜', price: 45 },
  p12: { name: '滷香豆干', price: 50 },
  gift: { name: '招牌招財鍋貼禮盒 50 入', price: 680 },
};
const METHODS = ['外帶', '內用', '宅配'];
const ORDER_HEADERS = ['訂單編號', '建立時間', '狀態', '取餐方式', '姓名', '電話', 'Email', '宅配地址', '品項摘要', '數量合計', '訂單金額', '備註', '更新時間'];
const ITEM_HEADERS = ['訂單編號', '品項代碼', '品名', '單價', '數量', '小計'];
const STATUSES = ['已收到', '製作中', '可取餐', '已完成', '已取消'];
const STATUS_COL = 3;   // C 欄：狀態
const UPDATED_COL = 13; // M 欄：更新時間
// 舊資料的狀態值對應到新狀態
const LEGACY_STATUS = { '新訂單': '已收到', '已確認': '已收到' };

// ===== 進入點 =====
function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.action === 'lookup') return lookup_(p);
  return json_({ ok: true, service: 'guocui-orders' });
}

/** 試算表被手動編輯時，狀態欄一變就自動更新「更新時間」（簡易觸發器，不需額外授權） */
function onEdit(e) {
  try {
    const r = e && e.range;
    if (!r) return;
    const sh = r.getSheet();
    if (sh.getName() !== CONFIG.ORDER_SHEET) return;
    if (r.getRow() < 2 || r.getColumn() > STATUS_COL || r.getLastColumn() < STATUS_COL) return;
    sh.getRange(r.getRow(), UPDATED_COL, r.getNumRows(), 1).setValue(new Date());
  } catch (err) {
    console.error(err);
  }
}

// ===== 訂單查詢（電話 + 訂單編號）=====
function lookup_(p) {
  const notFound = () => json_({ ok: false, error: '找不到訂單，請確認訂單編號與電話是否正確。' });
  const orderId = String(p.orderId || '').trim().toUpperCase();
  const phone = digits_(p.phone);
  if (!orderId || phone.length < 8) return notFound();

  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sh = ss.getSheetByName(CONFIG.ORDER_SHEET);
  if (!sh || sh.getLastRow() < 2) return notFound();

  const rows = sh.getRange(2, 1, sh.getLastRow() - 1, ORDER_HEADERS.length).getValues();
  const row = rows.filter(r => String(r[0]).toUpperCase() === orderId)[0];
  // 編號錯或電話錯回應相同，避免被用來探測訂單
  if (!row || digits_(row[5]) !== phone) return notFound();

  const fmt = v => (v instanceof Date ? Utilities.formatDate(v, CONFIG.TIMEZONE, 'yyyy/MM/dd HH:mm') : String(v || ''));
  const rawStatus = String(row[STATUS_COL - 1] || '').trim();
  const status = LEGACY_STATUS[rawStatus] || rawStatus || '已收到';

  const itemSheet = ss.getSheetByName(CONFIG.ITEM_SHEET);
  let items = [];
  if (itemSheet && itemSheet.getLastRow() >= 2) {
    items = itemSheet.getRange(2, 1, itemSheet.getLastRow() - 1, ITEM_HEADERS.length).getValues()
      .filter(r => String(r[0]).toUpperCase() === orderId)
      .map(r => ({ name: String(r[2]), price: Number(r[3]), qty: Number(r[4]), subtotal: Number(r[5]) }));
  }
  return json_({
    ok: true,
    orderId: String(row[0]),
    status: status,
    total: Number(row[10]),
    createdAt: fmt(row[1]),
    updatedAt: fmt(row[UPDATED_COL - 1] || row[1]),
    items: items,
  });
}

function digits_(v) {
  return String(v == null ? '' : v).replace(/\D/g, '');
}

function doPost(e) {
  try {
    const data = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (data.website) return json_({ ok: true, orderId: 'IGNORED' }); // 防機器人欄位
    const order = validate_(data);

    const lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      const ss = SpreadsheetApp.getActiveSpreadsheet();
      const orderSheet = sheet_(ss, CONFIG.ORDER_SHEET, ORDER_HEADERS);
      const itemSheet = sheet_(ss, CONFIG.ITEM_SHEET, ITEM_HEADERS);
      const now = new Date();
      order.id = nextOrderId_(now);
      orderSheet.appendRow([
        order.id, now, '已收到', order.method, order.name, "'" + order.phone, order.email,
        order.address, order.summary, order.count, order.total, order.note, now,
      ]);
      order.items.forEach(it => itemSheet.appendRow([order.id, it.id, it.name, it.price, it.qty, it.price * it.qty]));
    } finally {
      lock.releaseLock();
    }

    notify_(order);
    return json_({ ok: true, orderId: order.id, total: order.total });
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: err.userMessage || '訂單送出失敗，請稍後再試或直接致電門市。' });
  }
}

// ===== 驗證與計價 =====
function validate_(d) {
  const fail = msg => { const e = new Error(msg); e.userMessage = msg; throw e; };
  const clean = (v, max) => String(v == null ? '' : v).replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, max);
  // 防止試算表公式注入
  const safe = s => (/^[=+\-@]/.test(s) ? "'" + s : s);

  const name = safe(clean(d.name, 50));
  const phone = clean(d.phone, 20);
  const email = clean(d.email, 100);
  const method = clean(d.method, 10);
  const address = safe(clean(d.address, 200));
  const note = safe(clean(d.note, 300));

  if (!name) fail('請填寫姓名。');
  if (!/^[0-9+()\-\s]{8,20}$/.test(phone)) fail('電話格式不正確。');
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail('Email 格式不正確。');
  if (METHODS.indexOf(method) < 0) fail('取餐方式不正確。');
  if (method === '宅配' && !address) fail('宅配需填寫地址。');

  const items = [];
  const cart = d.items && typeof d.items === 'object' ? d.items : {};
  Object.keys(cart).forEach(id => {
    const qty = Number(cart[id]);
    const p = PRICE_LIST[id];
    if (!p) fail('購物車內有已下架的品項，請重新整理後再試。');
    if (!Number.isInteger(qty) || qty < 1 || qty > 99) fail('品項數量不正確。');
    items.push({ id: id, name: p.name, price: p.price, qty: qty });
  });
  if (!items.length) fail('購物車是空的。');

  const total = items.reduce((s, it) => s + it.price * it.qty, 0);
  const count = items.reduce((s, it) => s + it.qty, 0);
  const summary = items.map(it => it.name + ' x' + it.qty).join('、');
  return { name, phone, email, method, address: method === '宅配' ? address : '', note, items, total, count, summary };
}

// ===== 工具 =====
function nextOrderId_(now) {
  const props = PropertiesService.getScriptProperties();
  const day = Utilities.formatDate(now, CONFIG.TIMEZONE, 'yyyyMMdd');
  const key = 'seq_' + day;
  const seq = Number(props.getProperty(key) || 0) + 1;
  props.setProperty(key, String(seq));
  return CONFIG.ORDER_PREFIX + day + '-' + ('000' + seq).slice(-4);
}

function sheet_(ss, name, headers) {
  let sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.appendRow(headers);
    sh.setFrozenRows(1);
    sh.getRange(1, 1, 1, headers.length).setFontWeight('bold').setBackground('#38291f').setFontColor('#ffffff');
  }
  return sh;
}

function notify_(o) {
  const lines = [
    '訂單編號：' + o.id,
    '取餐方式：' + o.method,
    '姓名：' + o.name,
    '電話：' + o.phone,
    o.email ? 'Email：' + o.email : null,
    o.address ? '宅配地址：' + o.address : null,
    o.note ? '備註：' + o.note : null,
    '',
    o.items.map(it => '・' + it.name + ' x' + it.qty + '　NT$ ' + it.price * it.qty).join('\n'),
    '',
    '合計：NT$ ' + o.total,
  ].filter(l => l !== null).join('\n');
  try {
    if (CONFIG.NOTIFY_EMAIL) MailApp.sendEmail(CONFIG.NOTIFY_EMAIL, '【鍋淬】新訂單 ' + o.id, lines);
    if (CONFIG.SEND_CUSTOMER_EMAIL && o.email) {
      MailApp.sendEmail(o.email, '【鍋淬】已收到您的訂單 ' + o.id,
        o.name + ' 您好，\n\n感謝您的訂購，門市確認後會與您聯繫。\n\n' + lines + '\n\n鍋淬 GUOCUI');
    }
  } catch (err) {
    console.error('寄信失敗', err); // 寄信失敗不影響訂單成立
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/** 在編輯器手動執行一次，用來授權並建立工作表 */
function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const orderSheet = sheet_(ss, CONFIG.ORDER_SHEET, ORDER_HEADERS);
  sheet_(ss, CONFIG.ITEM_SHEET, ITEM_HEADERS);
  // 舊工作表補上「更新時間」表頭
  const head = orderSheet.getRange(1, UPDATED_COL);
  if (!head.getValue()) {
    head.setValue(ORDER_HEADERS[UPDATED_COL - 1]).setFontWeight('bold').setBackground('#38291f').setFontColor('#ffffff');
  }
  // 狀態欄下拉選單（allowInvalid：保留舊資料的「新訂單」「已確認」不報錯）
  const rule = SpreadsheetApp.newDataValidation().requireValueInList(STATUSES).setAllowInvalid(true).build();
  orderSheet.getRange('C2:C').setDataValidation(rule);
}

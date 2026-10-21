--[[
  Records your auction house trading for the Ledger and Trades tabs:
    b  bought      buyouts when they go through; won bids when you take the item from the mail
    d  deposit     paid when an auction is created
    r  returned    deposit given back with a sale
    s  sold        gold received for a sale, when you take it from the mail
    e  expired     an auction came back unsold
    c  cancelled   an auction you cancelled came back
    l  lost        the deposit of an auction that came back unsold (expired or cancelled)
    i  traded in   gold another player gave you in a trade (no names are kept)
    o  traded out  gold you gave another player in a trade
  AuxStatsDB.events holds "time;kind;count;copper;item name" strings.
  (Plain file, not an aux module; it was a separate loader addon before.)
]]

AuxStatsDB = AuxStatsDB or {}

local db

------------------------------------------------------------------------------
-- recording
------------------------------------------------------------------------------
local function Add(kind, name, n, copper)
  if not db then return end
  table.insert(db.events, string.format("%d;%s;%d;%d;%s", time(), kind, math.floor(n or 0),
    math.floor(copper or 0), name or "?"))
end
AuxStats_Add = Add   -- for testing

-- purchases: PlaceAuctionBid is confirmed by "Bid accepted."; buyouts count at once,
-- plain bids only if they are won (see the mail part)
local bids = {}
local origBid = PlaceAuctionBid
PlaceAuctionBid = function(kind, index, amount)
  local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo(kind, index)
  if name and amount and GetMoney() >= amount then
    table.insert(bids, { buy = (buyout or 0) > 0 and amount >= buyout, name = name,
      n = count or 1, g = amount, at = GetTime() })
  end
  return origBid(kind, index, amount)
end

-- posting: deposit, and a note of what was posted so a sale can be matched to its count
local posts = {}
local origStart = StartAuction
StartAuction = function(minBid, buyout, runTime)
  local name, _, count = GetAuctionSellItemInfo()
  if name then
    local deposit = CalculateAuctionDeposit and CalculateAuctionDeposit(runTime)
    table.insert(posts, { name = name, n = count or 1, bid = minBid or 0, buyout = buyout or 0,
      deposit = deposit, money = GetMoney(), at = GetTime() })
  end
  return origStart(minBid, buyout, runTime)
end

local function Expire(list, seconds)
  local now = GetTime()
  while list[1] and now - list[1].at > seconds do table.remove(list, 1) end
end

local waitingDeposit = nil   -- a post whose deposit had not left the purse yet

-- note a posted auction (with its deposit, so an unsold return can count it as lost)
local function Remember(p, deposit)
  table.insert(db.pending, string.format("%d;%d;%d;%d;%d;%s", time(), p.n, p.bid, p.buyout,
    math.floor(deposit or 0), p.name))
  while table.getn(db.pending) > 1000 do table.remove(db.pending, 1) end
  if deposit and deposit > 0 then Add("d", p.name, p.n, deposit) end
end

local function Posted()
  Expire(posts, 15)
  local p = table.remove(posts, 1)
  if not p then return end
  local deposit = p.deposit
  if not deposit then
    deposit = p.money - GetMoney()
    if deposit <= 0 then waitingDeposit = p return end
  end
  Remember(p, deposit)
end

-- the oldest posted auction of this item matching the sale (or with this count);
-- returns its stack size and deposit (nil for notes made before deposits were kept)
local function TakePending(name, buyout, bid, count)
  for i = 1, table.getn(db.pending) do
    local _, _, t, n, b, bo, dep, pname = string.find(db.pending[i], "^(%d+);(%d+);(%d+);(%d+);(%d+);(.*)$")
    if not t then
      _, _, t, n, b, bo, pname = string.find(db.pending[i], "^(%d+);(%d+);(%d+);(%d+);(.*)$")
      dep = nil
    end
    if pname == name then
      n, b, bo = tonumber(n), tonumber(b), tonumber(bo)
      local fits
      if count then fits = (n == count)
      elseif buyout and buyout > 0 then fits = (bo == buyout)
      else fits = bid and b <= bid end
      if fits then
        table.remove(db.pending, i)
        return n, tonumber(dep)
      end
    end
  end
end

-- mail: read an auction house mail just before it is taken
-- counted[i]: the mail at position i that was already counted, as "what it says" plus the
-- number of mails in the inbox. An open-all addon calls the mail functions several times
-- on the same mail, and the sale details (invoice) only arrive from the server after the
-- first call, often after the gold was already taken; the inbox only shrinks once the mail
-- is deleted, so the next identical sale moving into position i still counts.
local counted = {}
local expiredPattern, cancelledPattern
local function SubjectPattern(fmt)
  if not fmt then return nil end
  return "^" .. string.gsub(string.gsub(fmt, "([%(%)%.%[%]%+%-%*%?%^%$])", "%%%1"), "%%s", "(.+)") .. "$"
end

local function ReadMail(i)
  if not db or not i then return end
  local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
  if not subject then return end
  local tag = (sender or "") .. "|" .. subject .. "|" .. string.format("%.5f", daysLeft or 0) .. "#" .. (GetInboxNumItems and GetInboxNumItems() or 0)
  if counted[i] == tag then return end
  local invoiceType, itemName, _, bid, buyout, deposit, cut
  if GetInboxInvoiceInfo then invoiceType, itemName, _, bid, buyout, deposit, cut = GetInboxInvoiceInfo(i) end
  if invoiceType == "seller" then
    counted[i] = tag
    local n = TakePending(itemName, buyout, bid)
    Add("s", itemName, n or 0, (bid or 0) - (cut or 0))
    if deposit and deposit > 0 then Add("r", itemName, n or 0, deposit) end
  elseif invoiceType == "buyer" then
    counted[i] = tag
    -- buyouts were counted when bought; this is a bid you won
    if not ((buyout or 0) > 0 and (bid or 0) >= buyout) then
      local _, _, count = GetInboxItem(i)
      Add("b", itemName, count or 1, bid or 0)
    end
  else
    expiredPattern = expiredPattern or SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
    cancelledPattern = cancelledPattern or SubjectPattern(AUCTION_REMOVED_MAIL_SUBJECT)
    local kind
    if expiredPattern and string.find(subject, expiredPattern) then kind = "e"
    elseif cancelledPattern and string.find(subject, cancelledPattern) then kind = "c" end
    if kind then
      counted[i] = tag
      local name, _, count = GetInboxItem(i)
      name = name or string.gsub(subject, "^[^:]*:%s*", "")
      local _, deposit = TakePending(name, nil, nil, count)
      Add(kind, name, count or 1, 0)
      -- l: the deposit on an auction that came back unsold is gone for good
      if deposit and deposit > 0 then Add("l", name, count or 1, deposit) end
    end
  end
end

for _, fname in ipairs({ "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem" }) do
  local orig = getglobal(fname)
  if orig then
    setglobal(fname, function(i, a, b)
      local ok = pcall(ReadMail, i)
      return orig(i, a, b)
    end)
  end
end

------------------------------------------------------------------------------
-- trades: the gold on each side, noted while the window is open and recorded when the
-- trade goes through ("Trade complete.", or the purse changing by exactly that amount)
------------------------------------------------------------------------------
local trade = nil
local function TradeNote()
  if not trade then return end
  trade.mine = GetPlayerTradeMoney and GetPlayerTradeMoney() or trade.mine
  trade.theirs = GetTargetTradeMoney and GetTargetTradeMoney() or trade.theirs
end
local function TradeDone()
  local t = trade
  trade = nil
  if not t or not db then return end
  if (t.theirs or 0) > 0 then Add("i", "Trade", 1, t.theirs) end
  if (t.mine or 0) > 0 then Add("o", "Trade", 1, t.mine) end
end

------------------------------------------------------------------------------
-- events
------------------------------------------------------------------------------
local f = CreateFrame("Frame")
for _, e in ipairs({ "VARIABLES_LOADED", "CHAT_MSG_SYSTEM", "PLAYER_MONEY", "MAIL_SHOW", "MAIL_CLOSED",
    "TRADE_SHOW", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE" }) do
  f:RegisterEvent(e)
end
f:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    db = AuxStatsDB
    db.events = db.events or {}
    db.pending = db.pending or {}
    db.selected = db.selected or {}
    db.loadAlways = nil   -- setting of the old loader addon
    -- drop posted-auction notes older than 40 days (auctions plus 30 days of mail)
    local cutoff = time() - 40 * 86400
    while db.pending[1] and (tonumber((string.gsub(db.pending[1], ";.*", ""))) or 0) < cutoff do
      table.remove(db.pending, 1)
    end
  elseif event == "CHAT_MSG_SYSTEM" then
    if not db then return end
    if arg1 == ERR_AUCTION_BID_PLACED then
      Expire(bids, 15)
      local b = table.remove(bids, 1)
      if b and b.buy then Add("b", b.name, b.n, b.g) end
    elseif arg1 == ERR_AUCTION_STARTED then
      Posted()
    end
  elseif event == "MAIL_SHOW" or event == "MAIL_CLOSED" then
    for k in pairs(counted) do counted[k] = nil end
  elseif event == "TRADE_SHOW" then
    trade = { mine = 0, theirs = 0, money = GetMoney() }
    TradeNote()
  elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
    TradeNote()
  elseif event == "UI_INFO_MESSAGE" then
    if trade and ERR_TRADE_COMPLETE and arg1 == ERR_TRADE_COMPLETE then TradeDone() end
  elseif event == "TRADE_CLOSED" then
    -- no "Trade complete." seen: count it only if the purse changed by the traded gold
    local t = trade
    if t then
      t.closed = GetTime()
      local delta = (t.theirs or 0) - (t.mine or 0)
      if delta ~= 0 and GetMoney() - t.money == delta then TradeDone() end
    end
  elseif event == "PLAYER_MONEY" then
    -- the purse can change just after the trade window closes
    local t = trade
    if t and t.closed and GetTime() - t.closed < 5 then
      local delta = (t.theirs or 0) - (t.mine or 0)
      if delta ~= 0 and GetMoney() - t.money == delta then TradeDone() end
    end
    local p = waitingDeposit
    if p and db then
      waitingDeposit = nil
      local deposit = p.money - GetMoney()
      Remember(p, deposit > 0 and deposit or 0)
    end
  end
end)

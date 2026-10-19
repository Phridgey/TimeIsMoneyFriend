--[[
  Time is Money, Friend (loader): always loaded and small.

  1. Loads aux (which is now load-on-demand) during a loading screen that ends in
     Orgrimmar, Everlook or Gadgetzan; after walking or flying into one of them, once
     you stand still for a second; or when an auctioneer window opens before that (a pet
     auctioneer) -- that one visit then uses the Blizzard window.
     Once loaded it stays loaded until you reload or log out.
  2. Records your auction house trading for aux's Stats and Item stats tabs:
       b  bought      buyouts when they go through; won bids when you take the item from the mail
       d  deposit     paid when an auction is created
       r  returned    deposit given back with a sale
       s  sold        gold received for a sale, when you take it from the mail
       e  expired     an auction came back unsold
       c  cancelled   an auction you cancelled came back
       l  lost        the deposit of an auction that came back unsold (expired or cancelled)
     AuxStatsDB.events holds "time;kind;count;copper;item name" strings.
]]

AuxStatsDB = AuxStatsDB or {}

local db
local AH_PLACES = { ["Orgrimmar"] = true, ["Everlook"] = true, ["Gadgetzan"] = true }

------------------------------------------------------------------------------
-- loading aux
------------------------------------------------------------------------------
local function InAuctionPlace()
  return AH_PLACES[GetRealZoneText() or ""] or AH_PLACES[GetZoneText() or ""]
    or AH_PLACES[GetSubZoneText() or ""] or AH_PLACES[GetMinimapZoneText() or ""]
end

local DropSlashStub

local function LoadAux(auctionOpen)
  if IsAddOnLoaded("TimeIsMoneyFriend") then return end
  -- aux_late_ah: aux is being loaded by an auctioneer window that is open now; aux
  -- leaves that visit to the Blizzard window and takes over from the next one
  if auctionOpen then aux_late_ah = true end
  aux_late_load = true
  LoadAddOn("TimeIsMoneyFriend")
  DropSlashStub()
end

-- /timf loading: where aux loads (AuxStatsDB.loadAlways). Kept here so it works while aux
-- itself is not loaded; its own /timf calls these too.
function AuxStats_LoadingText()
  return (AuxStatsDB and AuxStatsDB.loadAlways) and "always" or "only in Orgrimmar, Everlook, Gadgetzan or at an auctioneer"
end

function AuxStats_ToggleLoading()
  AuxStatsDB.loadAlways = not AuxStatsDB.loadAlways or nil
  DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. "<TIMF> loading: " .. AuxStats_LoadingText() .. ".")
  if AuxStatsDB.loadAlways and not IsAddOnLoaded("TimeIsMoneyFriend") then
    LoadAux(false)
  elseif not AuxStatsDB.loadAlways and IsAddOnLoaded("TimeIsMoneyFriend") then
    DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. "<TIMF> it stays loaded until you reload or log out.")
  end
end

-- Until it is loaded, /timf is answered here: "loading" is handled without loading
-- aux; anything else loads aux and hands the command on.
SLASH_AUXSTUB1 = "/timf"
SlashCmdList["AUXSTUB"] = function(msg)
  if string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1")) == "loading" then
    AuxStats_ToggleLoading()
    return
  end
  LoadAux(false)
  if SlashCmdList["AUX"] then SlashCmdList["AUX"](msg or "") end
end

function DropSlashStub()
  SLASH_AUXSTUB1 = nil
  SlashCmdList["AUXSTUB"] = nil
end

-- In town without a loading screen (walked or flew in): load once you have stood still
-- for a second out of combat, so the short pause never lands while you are moving.
local inWorld = false   -- set at the first PLAYER_ENTERING_WORLD: aux needs login done
local still = CreateFrame("Frame")
local stillTick, stillSince, lastX, lastY = 0, nil, nil, nil
local function PlayerXY()
  if type(zAPI) == "function" then
    local ok, x, y = pcall(zAPI, "unitPosition", "player")
    if ok and x then return x, y, 0.2 end
  end
  local x, y = GetPlayerMapPosition("player")
  return x, y, 0.0005
end
still:SetScript("OnUpdate", function()
  stillTick = stillTick + arg1
  if stillTick < 0.25 then return end
  stillTick = 0
  if IsAddOnLoaded("TimeIsMoneyFriend") then this:SetScript("OnUpdate", nil) return end
  if not inWorld or not InAuctionPlace() or UnitAffectingCombat("player") then stillSince = nil return end
  local x, y, slack = PlayerXY()
  local now = GetTime()
  if not x or not lastX or math.abs(x - lastX) > slack or math.abs(y - lastY) > slack then
    stillSince = now
  end
  lastX, lastY = x, y
  if stillSince and now - stillSince >= 1 then LoadAux(false) end
end)

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
local seen = {}
local expiredPattern, cancelledPattern
local function SubjectPattern(fmt)
  if not fmt then return nil end
  return "^" .. string.gsub(string.gsub(fmt, "([%(%)%.%[%]%+%-%*%?%^%$])", "%%%1"), "%%s", "(.+)") .. "$"
end

local function ReadMail(i)
  if not db or not i then return end
  local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
  if not subject then return end
  local key = (sender or "") .. "|" .. subject .. "|" .. (money or 0) .. "|" .. math.floor((daysLeft or 0) * 1440)
  if seen[key] then return end
  local invoiceType, itemName, _, bid, buyout, deposit, cut
  if GetInboxInvoiceInfo then invoiceType, itemName, _, bid, buyout, deposit, cut = GetInboxInvoiceInfo(i) end
  if invoiceType == "seller" then
    seen[key] = true
    local n = TakePending(itemName, buyout, bid)
    Add("s", itemName, n or 0, (bid or 0) - (cut or 0))
    if deposit and deposit > 0 then Add("r", itemName, n or 0, deposit) end
  elseif invoiceType == "buyer" then
    seen[key] = true
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
      seen[key] = true
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
-- events
------------------------------------------------------------------------------
local f = CreateFrame("Frame")
for _, e in ipairs({ "VARIABLES_LOADED", "PLAYER_ENTERING_WORLD",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "CHAT_MSG_SYSTEM", "PLAYER_MONEY" }) do
  f:RegisterEvent(e)
end
f:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    db = AuxStatsDB
    db.events = db.events or {}
    db.pending = db.pending or {}
    db.selected = db.selected or {}
    -- drop posted-auction notes older than 40 days (auctions plus 30 days of mail)
    local cutoff = time() - 40 * 86400
    while db.pending[1] and (tonumber((string.gsub(db.pending[1], ";.*", ""))) or 0) < cutoff do
      table.remove(db.pending, 1)
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    LoadAux(true)
  elseif event == "AUCTION_HOUSE_CLOSED" then
    aux_late_ah = nil
  elseif event == "CHAT_MSG_SYSTEM" then
    if not db then return end
    if arg1 == ERR_AUCTION_BID_PLACED then
      Expire(bids, 15)
      local b = table.remove(bids, 1)
      if b and b.buy then Add("b", b.name, b.n, b.g) end
    elseif arg1 == ERR_AUCTION_STARTED then
      Posted()
    end
  elseif event == "PLAYER_MONEY" then
    local p = waitingDeposit
    if p and db then
      waitingDeposit = nil
      local deposit = p.money - GetMoney()
      Remember(p, deposit > 0 and deposit or 0)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- the end of a loading screen: loading aux here is hidden by the screen. Arriving in
    -- town without one (walking, flying) waits for the auctioneer window instead, so the
    -- pause never lands while you are moving.
    inWorld = true
    if (db and db.loadAlways) or InAuctionPlace() then LoadAux(false) end
  end
end)

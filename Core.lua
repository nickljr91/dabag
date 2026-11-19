local ADDON, ns = ...

ns.LOCKED = "__locked" -- bag assignment meaning "never move anything in or out of this bag"
ns.KEYRING = -1

local BUILTIN_FIRST = {
	{ key = "gear", name = "Gear" },
	{ key = "consumable", name = "Potions & Food" },
	{ key = "trade", name = "Trade Goods" },
	{ key = "quest", name = "Quest Items" },
}
local BUILTIN_LAST = {
	{ key = "misc", name = "Other" },
	{ key = "junk", name = "Junk" },
}

local DEFAULTS = { autoSort = true, view = "bags", columns = 10, bankColumns = 14, scale = 1 }

function ns.Print(msg)
	print("|cff66ccffDaBag|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Categories
---------------------------------------------------------------------------

-- Ordered list: built-in, then the player's own, then Other and Junk.
function ns.GetCategories()
	local list = {}
	for _, c in ipairs(BUILTIN_FIRST) do list[#list + 1] = c end
	for _, c in ipairs(ns.db.customCats) do list[#list + 1] = c end
	for _, c in ipairs(BUILTIN_LAST) do list[#list + 1] = c end
	return list
end

function ns.CatName(key)
	for _, c in ipairs(ns.GetCategories()) do
		if c.key == key then return c.name end
	end
end

function ns.AddCategory(name)
	name = strtrim(name or "")
	if name == "" then return end
	for _, c in ipairs(ns.GetCategories()) do
		if c.name:lower() == name:lower() then return c.key end
	end
	local key = "custom:" .. name:lower()
	table.insert(ns.db.customCats, { key = key, name = name })
	return key
end

function ns.DeleteCategory(key)
	for i, c in ipairs(ns.db.customCats) do
		if c.key == key then
			table.remove(ns.db.customCats, i)
			break
		end
	end
	for id, k in pairs(ns.db.itemCat) do
		if k == key then ns.db.itemCat[id] = nil end
	end
end

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
ns.GetItemInfoInstant = GetItemInfoInstant

function ns.Categorize(itemID, quality)
	local override = ns.db.itemCat[itemID]
	if override and ns.CatName(override) then return override end
	if quality == 0 then return "junk" end
	local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
	if classID == 12 then return "quest" end
	if classID == 2 or classID == 4 then return "gear" end
	if classID == 0 then return "consumable" end
	if classID == 7 or classID == 5 or classID == 9 then return "trade" end
	return "misc"
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

function ns.BagSize(bag)
	if bag == ns.KEYRING then
		local shown = C_ActionBar and C_ActionBar.ShouldShowKeyring and C_ActionBar.ShouldShowKeyring()
		if not shown or not GetKeyRingSize then return 0 end
		return GetKeyRingSize() or 0
	end
	return C_Container.GetContainerNumSlots(bag) or 0
end

-- Every carried bag that has slots, in display order.
function ns.DisplayBags()
	local list = {}
	local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5
	for bag = 0, last do
		if ns.BagSize(bag) > 0 then list[#list + 1] = bag end
	end
	if ns.BagSize(ns.KEYRING) > 0 then list[#list + 1] = ns.KEYRING end
	return list
end

function ns.BagName(bag)
	if bag == 0 then return BACKPACK_TOOLTIP or "Backpack" end
	if bag == ns.KEYRING then return KEYRING or "Keyring" end
	return C_Container.GetBagName(bag) or ("Bag " .. bag)
end

-- Only ordinary bags can be given a category. Quivers, profession bags, the reagent bag
-- and the keyring only accept certain items, so the sorter leaves them alone.
function ns.IsSortableBag(bag)
	if bag < 0 or bag > (NUM_BAG_SLOTS or 4) then return false end
	if bag == 0 then return true end
	local _, family = C_Container.GetContainerNumFreeSlots(bag)
	return (family or 0) == 0
end

-- nil = anything, ns.LOCKED = don't sort, otherwise a category key.
function ns.GetBagCat(bag)
	local v = ns.char.bagCat[bag]
	if v == ns.LOCKED then return v end
	if v and ns.CatName(v) then return v end
end

-- Starting layout for a new character. The backpack stays open for quest items, odds and
-- ends and overflow, so freshly looted items always have somewhere to land.
local DEFAULT_BAGS = { [1] = "gear", [2] = "consumable", [3] = "trade", [4] = "junk" }

function ns.ApplyDefaultBags()
	ns.char.bagCat = {}
	for bag, cat in pairs(DEFAULT_BAGS) do ns.char.bagCat[bag] = cat end
end

function ns.SetBagCat(bag, value)
	ns.char.bagCat[bag] = value
	ns.QueueAutoSort()
end

---------------------------------------------------------------------------
-- Bank cache (written at the banker, readable anywhere)
---------------------------------------------------------------------------

local function ScanBankType(bankType)
	if not (C_Bank and C_Bank.FetchPurchasedBankTabData) then return end
	if C_Bank.CanViewBank and not C_Bank.CanViewBank(bankType) then return end
	local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabData, bankType)
	if not ok or type(tabs) ~= "table" then return end
	local store = { time = time(), tabs = {} }
	for i, tab in ipairs(tabs) do
		local size = C_Container.GetContainerNumSlots(tab.ID) or 0
		local entry = { name = (tab.name and tab.name ~= "") and tab.name or ("Bank bag " .. i), size = size, items = {} }
		for slot = 1, size do
			local info = C_Container.GetContainerItemInfo(tab.ID, slot)
			if info and info.itemID then
				entry.items[slot] = {
					id = info.itemID,
					n = info.stackCount or 1,
					q = info.quality or 1,
					link = info.hyperlink,
					icon = info.iconFileID,
				}
			end
		end
		store.tabs[i] = entry
	end
	return store
end

function ns.ScanBank()
	if not ns.bankOpen or not (Enum and Enum.BankType) then return end
	local character = ScanBankType(Enum.BankType.Character)
	if character then ns.char.bank = character end
	local account = Enum.BankType.Account and ScanBankType(Enum.BankType.Account)
	if account and #account.tabs > 0 then ns.db.accountBank = account end
	ns.Refresh()
end

---------------------------------------------------------------------------
-- Startup and events
---------------------------------------------------------------------------

local function InitDB()
	DaBagDB = DaBagDB or {}
	local db = DaBagDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.itemCat = db.itemCat or {}
	db.customCats = db.customCats or {}
	db.chars = db.chars or {}
	ns.db = db

	local guid = UnitGUID("player") or UnitName("player")
	db.chars[guid] = db.chars[guid] or {}
	ns.charKey = guid
	ns.char = db.chars[guid]
	ns.char.name = UnitName("player")
	if not ns.char.bagCat then
		ns.ApplyDefaultBags()
		ns.Print("Bags are set up: gear, potions & food, trade goods and junk each have a bag. New items are filed automatically; click a bag's name to change what it holds.")
	end
end

local refreshQueued
function ns.Refresh()
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0, function()
		refreshQueued = false
		if ns.UpdateWindow then ns.UpdateWindow() end
	end)
end

---------------------------------------------------------------------------
-- Automatic sorting
---------------------------------------------------------------------------

local function Shown(name)
	local f = _G[name]
	return f and f.IsShown and f:IsShown()
end

-- Moving items around while the player is selling, mailing, trading or banking would pull
-- things out from under the mouse, so automatic sorting waits until those windows close.
local function AutoSortMustWait()
	return InCombatLockdown() or CursorHasItem() or ns.bankOpen or Shown("MerchantFrame") or Shown("MailFrame")
		or Shown("TradeFrame") or Shown("AuctionHouseFrame") or Shown("AuctionFrame")
end

local autoQueued
function ns.QueueAutoSort()
	if autoQueued or not ns.db or not ns.db.autoSort then return end
	autoQueued = true
	C_Timer.After(0.6, function()
		autoQueued = false
		if not ns.db.autoSort or ns.autoSortFailed or ns.IsSorting() or AutoSortMustWait() then return end
		ns.StartSort(true)
	end)
end

local AUTO_SORT_EVENTS = {
	BAG_UPDATE_DELAYED = true, PLAYER_REGEN_ENABLED = true, MERCHANT_CLOSED = true, BANKFRAME_CLOSED = true,
	MAIL_CLOSED = true, TRADE_CLOSED = true, AUCTION_HOUSE_CLOSED = true,
}

local frame = CreateFrame("Frame")
local EVENTS = {
	"MERCHANT_CLOSED", "MAIL_CLOSED", "TRADE_CLOSED", "AUCTION_HOUSE_CLOSED",
	"PLAYER_LOGIN", "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "ITEM_LOCK_CHANGED", "BAG_CONTAINER_UPDATE",
	"PLAYER_MONEY", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED",
	"PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "BANK_TABS_CHANGED", "PLAYER_REGEN_ENABLED",
}
for _, event in ipairs(EVENTS) do
	pcall(frame.RegisterEvent, frame, event) -- an event this client doesn't know is simply skipped
end

frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		InitDB()
		ns.InitWindow()
		return
	end
	if not ns.db then return end
	if AUTO_SORT_EVENTS[event] then ns.QueueAutoSort() end
	if event == "BANKFRAME_OPENED" then
		ns.bankOpen = true
		ns.ScanBank()
		C_Timer.After(0.5, ns.ScanBank)
	elseif event == "BANKFRAME_CLOSED" then
		ns.bankOpen = false
	elseif event == "PLAYER_REGEN_ENABLED" then
		ns.ParkBlizzardBags()
	elseif ns.bankOpen and event ~= "PLAYER_MONEY" and event ~= "BAG_UPDATE_COOLDOWN" and event ~= "ITEM_LOCK_CHANGED" then
		ns.ScanBank()
	end
	ns.Refresh()
end)

SLASH_DABAG1 = "/dabag"
SLASH_DABAG2 = "/dab"
SlashCmdList.DABAG = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "sort" then
		ns.StartSort()
	elseif msg == "bank" then
		ns.ShowWindow("bank")
	elseif msg == "reset" then
		ns.ResetPosition()
	elseif msg == "" then
		ns.ToggleWindow()
	else
		ns.Print("/dab - open or close   |   /dab sort   |   /dab bank   |   /dab reset (window position)")
	end
end

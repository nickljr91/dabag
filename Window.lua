local ADDON, ns = ...

local SIZE, GAP, PAD = 37, 4, 12
local TOP, BOTTOM, HEADER_H = 86, 30, 20
local MIN_WIDTH = 440
local ANYTHING = "" -- menu value for "this bag takes anything"

local window, scroll, content, emptyText, footerLeft, footerRight, sortButton, bankButton, searchBox
local viewButtons = {}
local scope = "bags" -- "bags" or "bank"
local searchText = ""
local bankCharKey -- whose bank is shown; nil = this character

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function Call(obj, method, ...)
	local fn = obj[method]
	if fn then pcall(fn, obj, ...) end
end

local function QualityColor(quality)
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
	if color then return color.r, color.g, color.b end
	return 1, 1, 1
end

local function Matches(name)
	if searchText == "" then return true end
	return name ~= nil and name:lower():find(searchText, 1, true) ~= nil
end

local function NameFromLink(link)
	return link and link:match("%[(.-)%]")
end

local function OpenMenu(owner, build)
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner, build)
	else
		ns.Print("This client has no menu support; use /dab.")
	end
end

---------------------------------------------------------------------------
-- Category menus
---------------------------------------------------------------------------

StaticPopupDialogs["DABAG_NEW_CATEGORY"] = {
	text = "Name of the new category:",
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(self, data)
		local box = self.EditBox or self.editBox or (self.GetEditBox and self:GetEditBox())
		local key = box and ns.AddCategory(box:GetText())
		if key and data and data.itemID then ns.db.itemCat[data.itemID] = key end
		ns.Refresh()
	end,
	EditBoxOnEnterPressed = function(self)
		local dialog = self:GetParent()
		local key = ns.AddCategory(self:GetText())
		if key and dialog.data and dialog.data.itemID then ns.db.itemCat[dialog.data.itemID] = key end
		dialog:Hide()
		ns.Refresh()
	end,
}

-- Which category a bag holds. Opened by clicking a bag's header in the Bags view.
local function BagMenu(owner, bag)
	OpenMenu(owner, function(_, root)
		root:CreateTitle(ns.BagName(bag) .. " holds:")
		local function isSelected(value)
			return (ns.char.bagCat[bag] or ANYTHING) == value
		end
		local function select(value)
			ns.SetBagCat(bag, value ~= ANYTHING and value or nil)
			ns.Refresh()
		end
		root:CreateRadio("Anything (overflow)", isSelected, select, ANYTHING)
		for _, cat in ipairs(ns.GetCategories()) do
			root:CreateRadio(cat.name .. " only", isSelected, select, cat.key)
		end
		root:CreateDivider()
		root:CreateRadio("Don't sort this bag", isSelected, select, ns.LOCKED)
	end)
end

-- Which category one particular item belongs to. Opened by Alt+left-click on an item.
local function ItemMenu(owner, itemID, name)
	OpenMenu(owner, function(_, root)
		root:CreateTitle((name or "Item") .. " belongs in:")
		local function isSelected(value)
			return (ns.db.itemCat[itemID] or ANYTHING) == value
		end
		local function select(value)
			ns.db.itemCat[itemID] = value ~= ANYTHING and value or nil
			ns.Refresh()
		end
		root:CreateRadio("Automatic", isSelected, select, ANYTHING)
		for _, cat in ipairs(ns.GetCategories()) do
			root:CreateRadio(cat.name, isSelected, select, cat.key)
		end
		root:CreateDivider()
		root:CreateButton("New category...", function()
			StaticPopup_Show("DABAG_NEW_CATEGORY", nil, nil, { itemID = itemID })
		end)
	end)
end

local function OptionsMenu(owner)
	OpenMenu(owner, function(_, root)
		root:CreateTitle("DaBag")
		root:CreateCheckbox("Sort automatically when bags change", function() return ns.db.autoSort end, function()
			ns.db.autoSort = not ns.db.autoSort
			ns.QueueAutoSort()
		end)
		local key = scope == "bank" and "bankColumns" or "columns"
		local columns = root:CreateButton("Columns")
		for _, n in ipairs({ 8, 10, 12, 14, 16, 18 }) do
			columns:CreateRadio(tostring(n), function() return ns.db[key] == n end, function()
				ns.db[key] = n
				ns.Refresh()
			end)
		end
		local scale = root:CreateButton("Window size")
		for _, s in ipairs({ 0.8, 0.9, 1, 1.1, 1.2 }) do
			scale:CreateRadio(math.floor(s * 100 + 0.5) .. "%", function() return ns.db.scale == s end, function()
				ns.db.scale = s
				ns.Refresh()
			end)
		end
		root:CreateDivider()
		root:CreateButton("New category...", function() StaticPopup_Show("DABAG_NEW_CATEGORY") end)
		if #ns.db.customCats > 0 then
			local delete = root:CreateButton("Delete category")
			for _, cat in ipairs(ns.db.customCats) do
				delete:CreateButton(cat.name, function()
					ns.DeleteCategory(cat.key)
					ns.Refresh()
				end)
			end
		end
		root:CreateButton("Reset bags to the default layout", function()
			ns.ApplyDefaultBags()
			ns.Refresh()
		end)
		root:CreateButton("Forget all per-item choices", function()
			wipe(ns.db.itemCat)
			ns.Refresh()
		end)
		root:CreateDivider()
		local chars = root:CreateButton("Show bank of")
		for key, char in pairs(ns.db.chars) do
			if char.bank then
				chars:CreateRadio(char.name or key, function() return (bankCharKey or ns.charKey) == key end, function()
					bankCharKey = key
					scope = "bank"
					ns.Refresh()
				end)
			end
		end
		root:CreateButton("Reset window position", ns.ResetPosition)
	end)
end

---------------------------------------------------------------------------
-- Item buttons
---------------------------------------------------------------------------

-- Live bag slots use Blizzard's own item button, so clicking, dragging, using, selling,
-- depositing, splitting and tooltips all behave exactly as in the default bags.
local holders, bagButtons = {}, {}

local function GetHolder(bag)
	local holder = holders[bag]
	if not holder then
		holder = CreateFrame("Frame", nil, content)
		holder:SetAllPoints(content)
		holder:SetID(bag)
		-- Blizzard's button occasionally asks its parent these questions.
		holder.GetBagID = function() return bag end
		holder.MatchesBagID = function(_, id) return id == bag end
		holder.IsCombinedBagContainer = function() return false end
		holder.IsBackpack = function() return bag == 0 end
		holders[bag] = holder
		bagButtons[bag] = {}
	end
	return holder
end

local function GetBagButton(bag, slot)
	local holder = GetHolder(bag)
	local button = bagButtons[bag][slot]
	if button then return button end
	local name = "DaBagItem" .. (bag < 0 and "K" or bag) .. "_" .. slot
	button = CreateFrame("ItemButton", name, holder, "ContainerFrameItemButtonTemplate")
	button:SetID(slot)
	if button.SetBagID then button:SetBagID(bag) end
	button.bzBag = bag
	button:SetSize(SIZE, SIZE)
	local bg = button:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.45)
	button:HookScript("OnClick", function(self, mouseButton)
		if mouseButton == "LeftButton" and IsAltKeyDown() and self.bzInfo then
			ItemMenu(self, self.bzInfo.itemID, self.bzInfo.itemName)
		end
	end)
	bagButtons[bag][slot] = button
	return button
end

local function PaintBagButton(button)
	local bag, slot = button.bzBag, button:GetID()
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local texture = info and info.iconFileID
	local quality = info and info.quality
	button.bzInfo = info

	local icon = button.icon or button.Icon or _G[button:GetName() .. "IconTexture"]
	if icon then
		icon:SetTexture(texture)
		icon:SetShown(texture ~= nil)
	end
	Call(button, "SetHasItem", texture)
	if SetItemButtonQuality then
		pcall(SetItemButtonQuality, button, quality, info and info.hyperlink, false, info and info.isBound)
	end
	if SetItemButtonCount then pcall(SetItemButtonCount, button, info and info.stackCount or 0) end
	if SetItemButtonDesaturated then pcall(SetItemButtonDesaturated, button, info and info.isLocked) end

	local ok, quest = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
	if ok and quest then
		Call(button, "UpdateQuestItem", quest.isQuestItem, quest.questID, quest.isActive)
	end
	Call(button, "UpdateNewItem", quality)
	Call(button, "UpdateJunkItem", quality, info and info.hasNoValue)

	if button.Cooldown then
		local shown = false
		if texture and CooldownFrame_Set then
			local okCD, start, duration, enable = pcall(C_Container.GetContainerItemCooldown, bag, slot)
			if okCD and start then shown = pcall(CooldownFrame_Set, button.Cooldown, start, duration, enable) end
		end
		if not shown then button.Cooldown:Hide() end
	end

	button:SetAlpha((info and not Matches(info.itemName)) and 0.2 or 1)
end

-- Bank contents come from the saved copy, so these are simple look-only buttons.
local cachedButtons, cachedUsed = {}, 0

local function GetCachedButton()
	cachedUsed = cachedUsed + 1
	local button = cachedButtons[cachedUsed]
	if button then return button end
	button = CreateFrame("Button", nil, content)
	button:SetSize(SIZE, SIZE)
	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.45)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.border = button:CreateTexture(nil, "OVERLAY")
	button.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	button.border:SetBlendMode("ADD")
	button.border:SetSize(SIZE * 1.75, SIZE * 1.75)
	button.border:SetPoint("CENTER")
	button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.count:SetPoint("BOTTOMRIGHT", -2, 2)
	button:SetScript("OnEnter", function(self)
		if self.data and self.data.link then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(self.data.link)
			GameTooltip:Show()
		end
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetScript("OnClick", function(self)
		if not self.data then return end
		if IsAltKeyDown() then
			ItemMenu(self, self.data.id, NameFromLink(self.data.link))
		elseif IsModifiedClick() and self.data.link then
			HandleModifiedItemClick(self.data.link)
		end
	end)
	cachedButtons[cachedUsed] = button
	return button
end

local function PaintCachedButton(button, data)
	button.data = data
	if data then
		button.icon:SetTexture(data.icon)
		button.icon:Show()
		button.count:SetText(data.n and data.n > 1 and data.n or "")
		if data.q and data.q > 1 then
			button.border:SetVertexColor(QualityColor(data.q))
			button.border:Show()
		else
			button.border:Hide()
		end
		button:SetAlpha(Matches(NameFromLink(data.link)) and 1 or 0.2)
	else
		button.icon:Hide()
		button.border:Hide()
		button.count:SetText("")
		button:SetAlpha(1)
	end
end

local headers, headersUsed = {}, 0

local function GetHeader()
	headersUsed = headersUsed + 1
	local header = headers[headersUsed]
	if header then return header end
	header = CreateFrame("Button", nil, content)
	header:SetHeight(HEADER_H - 2)
	header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header.text:SetPoint("LEFT", 2, 0)
	local highlight = header:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.08)
	header:SetScript("OnClick", function(self) if self.onClick then self.onClick(self) end end)
	header:SetScript("OnEnter", function(self)
		if self.tip then
			GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
			GameTooltip:SetText(self.tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	header:SetScript("OnLeave", GameTooltip_Hide)
	headers[headersUsed] = header
	return header
end

---------------------------------------------------------------------------
-- Sections: what goes where for each view
---------------------------------------------------------------------------

local function BagAssignmentText(bag)
	if not ns.IsSortableBag(bag) then return "|cff888888special bag, not sorted|r" end
	local cat = ns.GetBagCat(bag)
	if cat == ns.LOCKED then return "|cffff8888not sorted|r  (click to change)" end
	if cat then return "|cff66ff66" .. ns.CatName(cat) .. " only|r  (click to change)" end
	return "|cffffffffanything|r  (click to change)"
end

local function BagSections(view)
	local sections = {}
	local bags = ns.DisplayBags()

	-- Make sure a painted button exists for every slot; hide the rest.
	local live = {}
	for _, bag in ipairs(bags) do
		live[bag] = {}
		for slot = 1, ns.BagSize(bag) do
			local button = GetBagButton(bag, slot)
			PaintBagButton(button)
			live[bag][slot] = button
		end
	end
	for bag, buttons in pairs(bagButtons) do
		for slot, button in pairs(buttons) do
			if not (live[bag] and live[bag][slot]) then button:Hide() end
		end
	end

	if view == "bags" then
		for _, bag in ipairs(bags) do
			local sortable = ns.IsSortableBag(bag)
			sections[#sections + 1] = {
				title = ns.BagName(bag) .. "  -  " .. BagAssignmentText(bag),
				buttons = live[bag],
				tip = sortable and "Click to choose what this bag is for. Sort then moves matching items here." or nil,
				onClick = sortable and function(self) BagMenu(self, bag) end or nil,
			}
		end
	elseif view == "cats" then
		local catIndex, groups, empty = {}, {}, {}
		for i, cat in ipairs(ns.GetCategories()) do
			catIndex[cat.key] = i
			groups[i] = { title = cat.name, entries = {} }
		end
		for _, bag in ipairs(bags) do
			for _, button in ipairs(live[bag]) do
				local info = button.bzInfo
				if info and info.itemID then
					local _, _, _, _, _, classID, subClassID = ns.GetItemInfoInstant(info.itemID)
					local ci = catIndex[ns.Categorize(info.itemID, info.quality)] or #groups
					table.insert(groups[ci].entries, {
						button = button, ci = ci, classID = classID or 99, subClassID = subClassID or 99,
						quality = info.quality or 1, id = info.itemID, count = info.stackCount or 1,
						link = info.hyperlink or "",
					})
				else
					empty[#empty + 1] = button
				end
			end
		end
		for _, group in ipairs(groups) do
			if #group.entries > 0 then
				table.sort(group.entries, ns.ItemBefore)
				local buttons = {}
				for i, entry in ipairs(group.entries) do buttons[i] = entry.button end
				sections[#sections + 1] = { title = group.title .. "  (" .. #buttons .. ")", buttons = buttons }
			end
		end
		if #empty > 0 then
			sections[#sections + 1] = { title = "Empty  (" .. #empty .. ")", buttons = empty }
		end
	else
		local all = {}
		for _, bag in ipairs(bags) do
			for _, button in ipairs(live[bag]) do all[#all + 1] = button end
		end
		sections[1] = { buttons = all }
	end
	return sections
end

local function BankSections(view)
	local sections = {}
	local char = ns.db.chars[bankCharKey or ns.charKey] or ns.char
	local stores = {}
	if char.bank then stores[#stores + 1] = { label = "Bank", store = char.bank } end
	if ns.db.accountBank then stores[#stores + 1] = { label = "Account bank", store = ns.db.accountBank } end

	local function button(data)
		local b = GetCachedButton()
		PaintCachedButton(b, data)
		return b
	end

	if view == "bags" then
		for _, s in ipairs(stores) do
			for _, tab in ipairs(s.store.tabs) do
				local buttons = {}
				for slot = 1, tab.size do buttons[slot] = button(tab.items[slot]) end
				sections[#sections + 1] = { title = s.label .. ": " .. tab.name, buttons = buttons }
			end
		end
	elseif view == "cats" then
		local catIndex, groups = {}, {}
		for i, cat in ipairs(ns.GetCategories()) do
			catIndex[cat.key] = i
			groups[i] = { title = cat.name, entries = {} }
		end
		for _, s in ipairs(stores) do
			for _, tab in ipairs(s.store.tabs) do
				for slot = 1, tab.size do
					local data = tab.items[slot]
					if data then
						local _, _, _, _, _, classID, subClassID = ns.GetItemInfoInstant(data.id)
						local ci = catIndex[ns.Categorize(data.id, data.q)] or #groups
						table.insert(groups[ci].entries, {
							data = data, ci = ci, classID = classID or 99, subClassID = subClassID or 99,
							quality = data.q or 1, id = data.id, count = data.n or 1, link = data.link or "",
						})
					end
				end
			end
		end
		for _, group in ipairs(groups) do
			if #group.entries > 0 then
				table.sort(group.entries, ns.ItemBefore)
				local buttons = {}
				for i, entry in ipairs(group.entries) do buttons[i] = button(entry.data) end
				sections[#sections + 1] = { title = group.title .. "  (" .. #buttons .. ")", buttons = buttons }
			end
		end
	else
		for _, s in ipairs(stores) do
			local buttons = {}
			for _, tab in ipairs(s.store.tabs) do
				for slot = 1, tab.size do buttons[#buttons + 1] = button(tab.items[slot]) end
			end
			sections[#sections + 1] = { title = s.label, buttons = buttons }
		end
	end
	return sections, char
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local function Layout(sections, columns)
	local width = columns * (SIZE + GAP) - GAP
	local y = 0
	for _, section in ipairs(sections) do
		if section.title then
			local header = GetHeader()
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
			header:SetWidth(width)
			header.text:SetText(section.title)
			header.onClick, header.tip = section.onClick, section.tip
			header:Show()
			y = y + HEADER_H
		end
		for i, button in ipairs(section.buttons) do
			local col = (i - 1) % columns
			local row = math.floor((i - 1) / columns)
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", content, "TOPLEFT", col * (SIZE + GAP), -(y + row * (SIZE + GAP)))
			button:Show()
		end
		y = y + math.ceil(#section.buttons / columns) * (SIZE + GAP) + 6
	end
	return width, math.max(y, 1)
end

function ns.UpdateWindow()
	if not window or not window:IsShown() then return end
	local db = ns.db
	window:SetScale(db.scale or 1)

	headersUsed, cachedUsed = 0, 0
	local sections, bankChar
	local columns
	if scope == "bank" then
		columns = db.bankColumns
		for _, holder in pairs(holders) do holder:Hide() end
		sections, bankChar = BankSections(db.view)
	else
		columns = db.columns
		for _, holder in pairs(holders) do holder:Show() end
		sections = BagSections(db.view)
	end

	local width, height = Layout(sections, columns)
	for i = headersUsed + 1, #headers do headers[i]:Hide() end
	for i = cachedUsed + 1, #cachedButtons do cachedButtons[i]:Hide() end

	local noBank = scope == "bank" and #sections == 0
	emptyText:SetShown(noBank)
	if noBank then height = 60 end

	local maxHeight = math.max(200, UIParent:GetHeight() * 0.62 / (db.scale or 1))
	local viewHeight = math.min(height, maxHeight)
	content:SetSize(width, height)
	scroll:SetSize(width, viewHeight)
	local bar = scroll.ScrollBar or _G["DaBagScrollScrollBar"]
	if bar then bar:SetShown(height > viewHeight + 1) end
	window:SetSize(math.max(width + PAD * 2 + 22, MIN_WIDTH), viewHeight + TOP + BOTTOM)

	for view, button in pairs(viewButtons) do
		if view == db.view then button:LockHighlight() else button:UnlockHighlight() end
	end
	bankButton:SetText(scope == "bank" and "Show bags" or "Show bank")
	sortButton:SetEnabled(scope == "bags")

	if scope == "bank" then
		local when = bankChar and bankChar.bank and bankChar.bank.time
		footerLeft:SetText(when and ((bankChar.name or "Bank") .. " - saved " .. date("%d %b %H:%M", when)) or "")
		footerRight:SetText("view only")
	else
		local free, total = 0, 0
		for _, bag in ipairs(ns.DisplayBags()) do
			if bag ~= ns.KEYRING then
				total = total + ns.BagSize(bag)
				free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
			end
		end
		footerLeft:SetText(free .. " of " .. total .. " slots free")
		local money = GetMoney()
		if GetMoneyString then
			footerRight:SetText(GetMoneyString(money, true))
		elseif C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
			footerRight:SetText(C_CurrencyInfo.GetCoinTextureString(money))
		end
	end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function SavePosition()
	local right, bottom = window:GetRight(), window:GetBottom()
	if not right or not bottom then return end
	local s = window:GetScale()
	ns.db.pos = { x = right * s - UIParent:GetRight(), y = bottom * s - UIParent:GetBottom() }
end

local function ApplyPosition()
	window:ClearAllPoints()
	local pos = ns.db.pos
	local s = ns.db.scale or 1
	if pos then
		window:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", pos.x / s, pos.y / s)
	else
		window:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -60 / s, 120 / s)
	end
end

function ns.ResetPosition()
	ns.db.pos = nil
	ApplyPosition()
end

local function MakeButton(text, width, onClick, tip)
	local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	if tip then
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
	end
	return button
end

local function BuildWindow()
	window = CreateFrame("Frame", "DaBagFrame", UIParent, "BackdropTemplate")
	window:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	window:SetBackdropColor(0.05, 0.05, 0.07, 0.93)
	window:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	window:SetFrameStrata("HIGH")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
		ApplyPosition()
	end)
	window:SetScript("OnShow", function()
		PlaySound(SOUNDKIT and SOUNDKIT.IG_BACKPACK_OPEN or 862)
		ns.UpdateWindow()
	end)
	window:SetScript("OnHide", function() PlaySound(SOUNDKIT and SOUNDKIT.IG_BACKPACK_CLOSE or 863) end)
	window:Hide()
	tinsert(UISpecialFrames, "DaBagFrame") -- Escape closes it

	local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", PAD, -10)
	title:SetText("DaBag")

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() window:Hide() end)

	local function setView(view)
		return function()
			ns.db.view = view
			ns.Refresh()
		end
	end
	viewButtons.all = MakeButton("All", 44, setView("all"), "Everything in one grid.")
	viewButtons.bags = MakeButton("Bags", 52, setView("bags"),
		"One section per bag. Click a bag's name to choose what it is for.")
	viewButtons.cats = MakeButton("Categories", 84, setView("cats"),
		"Items grouped by category, wherever they are stored.")
	viewButtons.all:SetPoint("TOPLEFT", PAD, -34)
	viewButtons.bags:SetPoint("LEFT", viewButtons.all, "RIGHT", 2, 0)
	viewButtons.cats:SetPoint("LEFT", viewButtons.bags, "RIGHT", 2, 0)

	local options = MakeButton("Options", 62, function(self) OptionsMenu(self) end)
	options:SetPoint("TOPRIGHT", -PAD, -34)
	sortButton = MakeButton("Sort", 50, function() ns.StartSort(false) end,
		"Move every item into the bag assigned to its category. Anything that doesn't fit goes to the 'anything' bags.")
	sortButton:SetPoint("RIGHT", options, "LEFT", -2, 0)
	bankButton = MakeButton("Show bank", 84, function()
		scope = scope == "bank" and "bags" or "bank"
		bankCharKey = nil
		ns.Refresh()
	end, "Switch between your bags and the saved copy of your bank.")
	bankButton:SetPoint("RIGHT", sortButton, "LEFT", -2, 0)

	local ok, box = pcall(CreateFrame, "EditBox", "DaBagSearch", window, "SearchBoxTemplate")
	if not ok then box = CreateFrame("EditBox", "DaBagSearch", window, "InputBoxTemplate") end
	box:SetSize(160, 20)
	box:SetPoint("TOPLEFT", PAD + 6, -60)
	box:SetAutoFocus(false)
	box:HookScript("OnTextChanged", function(self)
		searchText = strtrim(self:GetText() or ""):lower()
		ns.Refresh()
	end)
	box:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
	searchBox = box

	local hint = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", box, "RIGHT", 10, 0)
	hint:SetText("Alt+click an item to set its category")

	local okScroll
	okScroll, scroll = pcall(CreateFrame, "ScrollFrame", "DaBagScroll", window, "UIPanelScrollFrameTemplate")
	if not okScroll then
		scroll = CreateFrame("ScrollFrame", "DaBagScroll", window)
		scroll:EnableMouseWheel(true)
		scroll:SetScript("OnMouseWheel", function(self, delta)
			local range = self:GetVerticalScrollRange()
			self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * (SIZE + GAP))))
		end)
	end
	scroll:SetPoint("TOPLEFT", PAD, -TOP)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(10, 10)
	scroll:SetScrollChild(content)

	emptyText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("TOPLEFT", scroll, "TOPLEFT", 4, -8)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetText("No bank saved for this character yet.\nOpen your bank once and it will be viewable from anywhere.")
	emptyText:Hide()

	footerLeft = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footerLeft:SetPoint("BOTTOMLEFT", PAD, 10)
	footerRight = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footerRight:SetPoint("BOTTOMRIGHT", -PAD, 10)

	ApplyPosition()
end

function ns.ShowWindow(newScope)
	if newScope then scope = newScope end
	if window:IsShown() then ns.Refresh() else window:Show() end
end

function ns.ToggleWindow()
	if window:IsShown() then window:Hide() else ns.ShowWindow() end
end

---------------------------------------------------------------------------
-- Taking over from the default bags
---------------------------------------------------------------------------

-- Hiding Blizzard's bag frames directly would taint them. Instead they are parked under an
-- invisible parent: Blizzard keeps opening and closing them as usual, they just never appear.
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

function ns.ParkBlizzardBags()
	if InCombatLockdown() then return end
	if ContainerFrameCombinedBags then ContainerFrameCombinedBags:SetParent(hiddenParent) end
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local bagFrame = _G["ContainerFrame" .. i]
		if bagFrame then bagFrame:SetParent(hiddenParent) end
	end
end

local pendingAction

local function ApplyPendingAction()
	local action = pendingAction
	pendingAction = nil
	ns.ParkBlizzardBags()
	if action == "toggle" then
		ns.ToggleWindow()
	elseif action == "show" then
		-- Opening bags at a banker or merchant should show the bags, not the saved bank.
		ns.ShowWindow("bags")
	elseif action == "hide" then
		window:Hide()
	end
end

-- Blizzard's bag functions call each other; only the outermost call (the last hook to run
-- in a frame) says what the player actually asked for.
local function Hook(name, action)
	if type(_G[name]) ~= "function" then return end
	hooksecurefunc(name, function()
		if not pendingAction then C_Timer.After(0, ApplyPendingAction) end
		pendingAction = action
	end)
end

function ns.InitWindow()
	BuildWindow()
	ns.ParkBlizzardBags()
	Hook("ToggleAllBags", "toggle")
	Hook("ToggleBackpack", "toggle")
	Hook("ToggleBag", "toggle")
	Hook("OpenAllBags", "show")
	Hook("OpenBackpack", "show")
	Hook("OpenBag", "show")
	Hook("CloseAllBags", "hide")
	Hook("CloseBackpack", "hide")
end

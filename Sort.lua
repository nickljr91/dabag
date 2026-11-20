local ADDON, ns = ...

-- The sorter never remembers a plan. Every pass it looks at the bags as they are now,
-- works out where everything should end up, and makes the swaps that are still needed.
-- A swap the server rejects is therefore just retried on the next pass.

local PASS_INTERVAL = 0.2
local TIMEOUT = 30

local function GetMaxStack(itemID)
	local getInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
	local maxStack = select(8, getInfo(itemID))
	return maxStack
end

-- slots: every slot of every sortable bag, in bag order. bags: those bags with their category.
function ns.Snapshot()
	local slots, bags, anyLocked = {}, {}, false
	for bag = 0, NUM_BAG_SLOTS or 4 do
		local size = ns.BagSize(bag)
		local cat = ns.GetBagCat(bag)
		if size > 0 and ns.IsSortableBag(bag) and cat ~= ns.LOCKED then
			bags[#bags + 1] = { bag = bag, cat = cat }
			for slot = 1, size do
				local entry = { bag = bag, slot = slot }
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and info.itemID then
					local _, _, _, _, _, classID, subClassID = ns.GetItemInfoInstant(info.itemID)
					local count = info.stackCount or 1
					entry.item = {
						id = info.itemID,
						count = count,
						quality = info.quality or 1,
						link = info.hyperlink or "",
						classID = classID or 99,
						subClassID = subClassID or 99,
						cat = ns.Categorize(info.itemID, info.quality),
						max = GetMaxStack(info.itemID),
						sig = (info.hyperlink or info.itemID) .. "*" .. count,
					}
					if info.isLocked then anyLocked = true end
				end
				slots[#slots + 1] = entry
			end
		end
	end
	return slots, bags, anyLocked
end

function ns.ItemBefore(a, b)
	if a.ci ~= b.ci then return a.ci < b.ci end
	if a.classID ~= b.classID then return a.classID < b.classID end
	if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
	if a.quality ~= b.quality then return a.quality > b.quality end
	if a.id ~= b.id then return a.id < b.id end
	if a.count ~= b.count then return a.count > b.count end
	return a.link < b.link
end

-- Returns target[slotIndex] = the item that should end up in that slot.
function ns.BuildTarget(slots, bags)
	local catIndex = {}
	for i, c in ipairs(ns.GetCategories()) do catIndex[c.key] = i end

	local items = {}
	for _, s in ipairs(slots) do
		if s.item then
			s.item.ci = catIndex[s.item.cat] or 999
			items[#items + 1] = s.item
		end
	end
	table.sort(items, ns.ItemBefore)

	local bagSlots = {}
	for i, s in ipairs(slots) do
		bagSlots[s.bag] = bagSlots[s.bag] or {}
		table.insert(bagSlots[s.bag], i)
	end

	-- Slots reserved for each category, and the slots of bags that take anything.
	local catSlots, general = {}, {}
	for _, b in ipairs(bags) do
		local dest = general
		if b.cat then
			catSlots[b.cat] = catSlots[b.cat] or {}
			dest = catSlots[b.cat]
		end
		for _, i in ipairs(bagSlots[b.bag] or {}) do dest[#dest + 1] = i end
	end

	-- Each item goes to its category's bag while there is room; the rest overflow.
	local target, overflow, used = {}, {}, {}
	for _, item in ipairs(items) do
		local list = catSlots[item.cat]
		local pos = (used[item.cat] or 0) + 1
		if list and pos <= #list then
			target[list[pos]] = item
			used[item.cat] = pos
		else
			overflow[#overflow + 1] = item
		end
	end

	-- Overflow fills the "anything" bags first, then spare room in the assigned bags.
	local free = {}
	for _, i in ipairs(general) do free[#free + 1] = i end
	for _, b in ipairs(bags) do
		if b.cat then
			for _, i in ipairs(bagSlots[b.bag] or {}) do
				if not target[i] then free[#free + 1] = i end
			end
		end
	end
	for k, item in ipairs(overflow) do target[free[k]] = item end
	return target
end

-- Two stacks of one item sometimes refuse to join (one is soulbound, on a timer or refundable
-- and the other is not). The game swaps them instead, which would repeat forever, so an item
-- whose partial stacks look the same after two join attempts is left alone for this sort.
local joinBefore, joinStrikes = {}, {}

-- Returns a list of {fromIndex, toIndex}; no slot appears twice in one pass.
function ns.ComputeMoves(slots, target)
	local moves = {}

	-- First join partial stacks, so that afterwards any two stacks of one item behave like a swap.
	local partial = {}
	for i, s in ipairs(slots) do
		local item = s.item
		if item and item.max and item.max > 1 and item.count < item.max then
			partial[item.id] = partial[item.id] or {}
			table.insert(partial[item.id], i)
		end
	end
	for id, list in pairs(partial) do
		if #list > 1 and (joinStrikes[id] or 0) < 2 then
			local counts = {}
			for k, i in ipairs(list) do counts[k] = slots[i].item.count end
			table.sort(counts)
			local state = table.concat(counts, ",")
			joinStrikes[id] = joinBefore[id] == state and (joinStrikes[id] or 0) + 1 or 0
			joinBefore[id] = state
			if joinStrikes[id] < 2 then
				for k = 2, #list, 2 do moves[#moves + 1] = { list[k], list[k - 1] } end
			end
		end
	end
	if #moves > 0 then return moves end

	local sources = {} -- signature -> slots holding that item which are not where they belong
	for j, s in ipairs(slots) do
		local item = s.item
		if item and not (target[j] and target[j].sig == item.sig) then
			sources[item.sig] = sources[item.sig] or {}
			table.insert(sources[item.sig], j)
		end
	end

	local busy = {}
	for i, s in ipairs(slots) do
		local want = target[i]
		if want and not busy[i] and not (s.item and s.item.sig == want.sig) then
			local list = sources[want.sig]
			while list and #list > 0 do
				local j = table.remove(list)
				if not busy[j] then
					moves[#moves + 1] = { j, i }
					busy[i], busy[j] = true, true
					break
				end
			end
		end
	end
	return moves
end

local ticker, startedAt, movedAnything, quiet

local function Stop(message)
	if ticker then ticker:Cancel() end
	ticker = nil
	if message and not quiet then ns.Print(message) end
	ns.Refresh()
end

local function Pass()
	if GetTime() - startedAt > TIMEOUT then
		-- Something keeps refusing to move. Don't let automatic sorting retry it forever.
		if quiet then ns.Print("Automatic sorting is paused until you press Sort or reload.") end
		ns.autoSortFailed = true
		return Stop("Sorting stopped after " .. TIMEOUT .. " seconds without finishing. Press Sort again to continue.")
	end
	if CursorHasItem() then return end -- the player is holding something; wait
	local slots, bags, anyLocked = ns.Snapshot()
	if anyLocked then return end -- the server is still confirming the previous moves
	local moves = ns.ComputeMoves(slots, ns.BuildTarget(slots, bags))
	if #moves == 0 then
		return Stop(movedAnything and "Bags sorted." or "Bags are already sorted.")
	end
	movedAnything = true
	for _, move in ipairs(moves) do
		local from, to = slots[move[1]], slots[move[2]]
		C_Container.PickupContainerItem(from.bag, from.slot)
		C_Container.PickupContainerItem(to.bag, to.slot)
		if CursorHasItem() then ClearCursor() end
	end
end

-- An error inside a pass would otherwise kill the timer silently and leave the sorter
-- believing it is still running, so nothing could ever start it again.
local function SafePass()
	local ok, err = pcall(Pass)
	if not ok then
		ns.autoSortFailed = true
		quiet = false
		Stop("Sorting hit an error and stopped: " .. tostring(err))
	end
end

-- auto: started by the addon after a bag change, so it stays silent in chat.
function ns.StartSort(auto)
	if ticker then
		if not auto then
			quiet = false -- the player asked, so report how the running sort ends
			ns.Print("Already sorting...")
		end
		return
	end
	quiet = auto and true or false
	if not auto then ns.autoSortFailed = false end
	if CursorHasItem() then ClearCursor() end
	startedAt, movedAnything = GetTime(), false
	joinBefore, joinStrikes = {}, {}
	ticker = C_Timer.NewTicker(PASS_INTERVAL, SafePass)
	SafePass()
end

function ns.IsSorting()
	return ticker ~= nil
end

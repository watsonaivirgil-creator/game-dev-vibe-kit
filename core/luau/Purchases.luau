--!nonstrict
-- Robux purchases done safely: game passes, developer products, receipts, an inbox of results. Game-neutral:
-- you list your passes and products and write one small handler per product; the engine does the hard parts.
--
--   local purchases = Purchases.new({
--       Passes   = { VIP = { Id = 111, Price = 149 } },                   -- Id 0 = "not created in Creator Hub yet": never sold or matched
--       Products = { Coins100 = { Id = 222, Price = 49 } },
--       Handlers = { Coins100 = function(player, profile) profile.Currencies.Coins += 100 return { Coins = 100 } end },
--       GetProfile = function(player) return profileTable end,
--       Save = function(player) return true end,                           -- must return true only once the data is durable
--       ProfileLoaded = profiles.ProfileLoaded,                            -- signal(player): passes are re-checked on join
--       SnapshotKeys = { "Currencies", "Inventory" },                      -- profile keys a failing handler may have touched
--   })
--   purchases:Start()
--
-- What it guarantees (all tested):
--   Dev products  ProcessReceipt is idempotent: each PurchaseId is stored in the profile; the grant and the record are
--                 applied together (a throwing handler rolls the snapshot keys back); Roblox is told "granted" ONLY
--                 after Save() succeeded. A crash or DataStore outage means Roblox retries: never lost, never doubled.
--   Game passes   Ownership lives on Roblox. It is mirrored into profile.Passes on join (a refund revokes), a failed
--                 lookup NEVER revokes, and a mid-session purchase is applied only after Roblox CONFIRMS ownership.
--   Results       Every purchase is pushed live AND stored in a capped inbox, so a purchase made while the client was
--                 busy or reconnecting is never silent (ClaimInbox).
--   Unknown ids   Left unprocessed (Roblox retries) and logged.
-- Your profile needs three tables (names configurable): Passes = {}, Receipts = {}, Inbox = {}.
--
-- Options: Passes, Products, Handlers, GetProfile, Save, ProfileLoaded, SnapshotKeys, OnRestore(player, profile),
--   ExtraShop(player, profile) -> table merged into GetShop, Limits = { MaxReceipts = 200, MaxInbox = 20 } (a live table),
--   PassesKey / ReceiptsKey / InboxKey.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Util = require(script.Parent.Util)

local Purchases = {}
Purchases.__index = Purchases

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet

function Purchases.new(opts)
	assert(type(opts) == "table", "Purchases.new needs an options table")
	assert(type(opts.GetProfile) == "function" and type(opts.Save) == "function", "Purchases.new: GetProfile and Save are required")
	local self = setmetatable({}, Purchases)
	self.passes = opts.Passes or {}
	self.products = opts.Products or {}
	self.Handlers = opts.Handlers or {} -- exposed: register handlers later (seasonal products, tests)
	self.getProfile = opts.GetProfile
	self.save = opts.Save
	self.profileLoaded = opts.ProfileLoaded
	self.snapshotKeys = opts.SnapshotKeys or {}
	self.onRestore = opts.OnRestore
	self.extraShop = opts.ExtraShop
	-- Limits is read live on every use, so a config table can be tuned at runtime (remote config, tests).
	self.limits = opts.Limits or { MaxReceipts = opts.MaxReceipts, MaxInbox = opts.MaxInbox }
	self.passesKey = opts.PassesKey or "Passes"
	self.receiptsKey = opts.ReceiptsKey or "Receipts"
	self.inboxKey = opts.InboxKey or "Inbox"

	local purchased = Instance.new("BindableEvent")
	-- Fires { Player, Kind = "DevProduct" | "GamePass", Name, Robux, PurchaseId? } the first time a purchase is applied.
	self.Purchased = purchased.Event
	self._purchased = purchased
	self.notifier = function(_player, _payload) end
	return self
end

-- fn(player, entry): wire to a RemoteEvent so the client sees purchases live.
function Purchases:SetNotifier(fn)
	self.notifier = fn or function() end
end

----------------------------------------------------------------------
-- lookups (IDs of 0 mean "not created yet" and never match anything)
----------------------------------------------------------------------
local function nameFor(defs, id): string?
	if typeof(id) ~= "number" or id == 0 then
		return nil
	end
	for name, def in defs do
		if def.Id ~= 0 and def.Id == id then
			return name
		end
	end
	return nil
end

----------------------------------------------------------------------
-- inbox
----------------------------------------------------------------------
function Purchases:_deliver(player, profile, entry)
	local inbox = profile[self.inboxKey]
	table.insert(inbox, entry)
	while #inbox > (self.limits.MaxInbox or 20) do
		table.remove(inbox, 1)
	end
	self.notifier(player, entry)
end

-- Returns the unseen results and clears them.
function Purchases:ClaimInbox(player)
	local profile = self.getProfile(player)
	if not profile then
		return nil, "Data not loaded"
	end
	local entries = Util.DeepCopy(profile[self.inboxKey])
	profile[self.inboxKey] = {}
	return entries
end

----------------------------------------------------------------------
-- developer products
----------------------------------------------------------------------
function Purchases:_snapshot(profile)
	local snapshot = {}
	for _, key in self.snapshotKeys do
		local value = profile[key]
		snapshot[key] = type(value) == "table" and Util.DeepCopy(value) or value
	end
	return snapshot
end

function Purchases:_restore(player, profile, snapshot)
	for key, value in snapshot do
		profile[key] = value
	end
	if self.onRestore then
		self.onRestore(player, profile)
	end
end

-- Roblox calls this for every developer product purchase (Start sets it). Idempotent and yield-safe.
function Purchases:ProcessReceipt(info)
	if typeof(info) ~= "table" then
		return NOT_YET
	end
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		return NOT_YET -- Roblox redelivers when the player rejoins
	end
	local profile = self.getProfile(player)
	if not profile then
		return NOT_YET
	end

	local purchaseId = tostring(info.PurchaseId)
	if profile[self.receiptsKey][purchaseId] then
		-- Already applied (a redelivery, or a retry after a failed save): never grant twice, just make it durable.
		return self.save(player) and GRANTED or NOT_YET
	end

	local name = nameFor(self.products, info.ProductId)
	local handler = name and self.Handlers[name]
	if not handler then
		warn(("[Purchases] unknown product id %s; left unprocessed"):format(tostring(info.ProductId)))
		return NOT_YET
	end

	local snapshot = self:_snapshot(profile)
	local ok, result = pcall(handler, player, profile)
	if not ok then
		self:_restore(player, profile, snapshot)
		warn(("[Purchases] granting %s failed and was rolled back: %s"):format(name, tostring(result)))
		return NOT_YET
	end

	profile[self.receiptsKey][purchaseId] = os.time()
	Util.TrimOldest(profile[self.receiptsKey], self.limits.MaxReceipts or 200)
	self:_deliver(player, profile, { Kind = "DevProduct", Product = name, Result = result, At = os.time() })
	self._purchased:Fire({
		Player = player,
		Kind = "DevProduct",
		Name = name,
		Robux = self.products[name].Price,
		PurchaseId = purchaseId,
	})
	return self.save(player) and GRANTED or NOT_YET
end

----------------------------------------------------------------------
-- game passes
----------------------------------------------------------------------
-- Returns ok, owns. ok=false means Roblox could not be asked (never treat that as "doesn't own").
local function ownsPass(userId: number, passId: number)
	for attempt = 1, 3 do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end)
		if ok then
			return true, owns == true
		end
		warn(("[Purchases] ownership check %d/3 failed: %s"):format(attempt, tostring(owns)))
		if attempt < 3 then
			task.wait(attempt)
		end
	end
	return false, false
end

-- Mirror Roblox ownership into the profile. Runs on join.
function Purchases:SyncPasses(player)
	local names = {}
	for name, def in self.passes do
		if def.Id ~= 0 then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		if not self.getProfile(player) then
			return
		end
		local ok, owns = ownsPass(player.UserId, self.passes[name].Id)
		local profile = self.getProfile(player)
		if not profile then
			return
		end
		if ok then
			profile[self.passesKey][name] = owns and true or nil -- false clears it: a refund or revoked pass
		end
	end
end

function Purchases:_onPassPurchaseFinished(player, passId, wasPurchased)
	if wasPurchased ~= true then
		return
	end
	local name = nameFor(self.passes, passId)
	if not name then
		return
	end
	-- Don't trust the client-reported event: ask Roblox. Ownership can lag a moment right after purchase.
	local owned = false
	for attempt = 1, 3 do
		local ok, owns = ownsPass(player.UserId, passId)
		if ok and owns then
			owned = true
			break
		end
		if attempt < 3 then
			task.wait(attempt)
		end
	end
	local profile = self.getProfile(player)
	if not owned or not profile then
		return
	end
	if profile[self.passesKey][name] then
		return -- already applied
	end
	profile[self.passesKey][name] = true
	self._purchased:Fire({ Player = player, Kind = "GamePass", Name = name, Robux = self.passes[name].Price })
	self:_deliver(player, profile, { Kind = "GamePass", Product = name, Result = {}, At = os.time() })
	self.save(player)
end

----------------------------------------------------------------------
-- shop view for the client
----------------------------------------------------------------------
function Purchases:GetShop(player)
	local profile = self.getProfile(player)
	local passes, products = {}, {}
	for name, def in self.passes do
		table.insert(passes, {
			Name = name,
			Id = def.Id,
			Price = def.Price,
			Available = def.Id ~= 0,
			Owned = profile ~= nil and profile[self.passesKey][name] == true,
		})
	end
	for name, def in self.products do
		table.insert(products, { Name = name, Id = def.Id, Price = def.Price, Available = def.Id ~= 0 })
	end
	local byName = function(x, y)
		return x.Name < y.Name
	end
	table.sort(passes, byName)
	table.sort(products, byName)
	local shop = { Passes = passes, Products = products, Now = os.time() }
	if self.extraShop then
		for key, value in self.extraShop(player, profile) do
			shop[key] = value
		end
	end
	return shop
end

----------------------------------------------------------------------
function Purchases:Start()
	MarketplaceService.ProcessReceipt = function(info)
		return self:ProcessReceipt(info)
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		self:_onPassPurchaseFinished(player, passId, wasPurchased)
	end)
	if self.profileLoaded then
		self.profileLoaded:Connect(function(player)
			self:SyncPasses(player)
		end)
	end
end

return Purchases

--!nonstrict
-- Player data persistence: load with retry, reconcile new fields into old saves, autosave, save on leave,
-- flush on shutdown. Game-neutral: you supply the store name and a function that builds a fresh profile.
--
--   local profiles = Profiles.new({
--       StoreName = "MyGame_Profiles_v1",
--       Template = function(player) return { Currencies = { Coins = 100 }, Inventory = {}, ... } end,
--       Freeform = { Inventory = true },     -- tables keyed by player data (item ids), never merged with the template
--   })
--   profiles:Start()
--   profiles.ProfileLoaded:Connect(function(player, data) ... end)
--   local data = profiles:Get(player)          -- nil until loaded
--   profiles:AddCurrency(player, "Coins", 50)  -- refuses non-integers, unknown currencies and overdrafts
--
-- Safety rules (tested):
--   * A failed load NEVER falls back to blank data (it would overwrite the real save on leave): the player is kicked.
--   * Missing fields in old saves are filled from the template, so adding a field needs no migration.
--   * Saves and loads retry with backoff; shutdown waits for every save.
-- Not included (add before a large launch): session locking, which stops two servers writing one profile.
-- Swap in ProfileStore/ProfileService behind the same Get / AddCurrency / Save calls if you need it.
--
-- Options: StoreName (required), Template (required), Freeform, AutosaveSeconds (60), Retries (4),
--   Key (function(player) -> string, default "Player_<UserId>"), CurrenciesKey ("Currencies"), InventoryKey ("Inventory"),
--   SyncAttributes (true: mirror currency values to player attributes so a HUD can bind to them),
--   KickMessage.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Util = require(script.Parent.Util)

local Profiles = {}
Profiles.__index = Profiles

function Profiles.new(opts)
	assert(type(opts) == "table", "Profiles.new needs an options table")
	assert(type(opts.StoreName) == "string", "Profiles.new: StoreName is required")
	assert(type(opts.Template) == "function", "Profiles.new: Template (a function returning a fresh profile) is required")
	local self = setmetatable({}, Profiles)
	self.opts = {
		Freeform = opts.Freeform or {},
		AutosaveSeconds = opts.AutosaveSeconds or 60,
		Retries = opts.Retries or 4,
		Key = opts.Key or function(player)
			return "Player_" .. player.UserId
		end,
		CurrenciesKey = opts.CurrenciesKey or "Currencies",
		InventoryKey = opts.InventoryKey or "Inventory",
		SyncAttributes = opts.SyncAttributes ~= false,
		KickMessage = opts.KickMessage or "Could not load your save data. Please rejoin.",
	}
	self.template = opts.Template
	self.store = DataStoreService:GetDataStore(opts.StoreName)
	self.profiles = {} -- [Player] = data table
	local loaded = Instance.new("BindableEvent")
	self.ProfileLoaded = loaded.Event -- fires (player, data) once a profile is ready
	self._loaded = loaded
	return self
end

function Profiles:_withRetry(fn)
	local lastErr
	for i = 1, self.opts.Retries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		warn(("[Profiles] attempt %d/%d failed: %s"):format(i, self.opts.Retries, tostring(result)))
		if i < self.opts.Retries then
			task.wait(2 ^ (i - 1))
		end
	end
	return false, lastErr
end

function Profiles:_syncAttributes(player, data)
	if not self.opts.SyncAttributes then
		return
	end
	for name, value in data[self.opts.CurrenciesKey] or {} do
		player:SetAttribute(name, value)
	end
end

function Profiles:_load(player)
	local ok, result = self:_withRetry(function()
		return self.store:GetAsync(self.opts.Key(player))
	end)
	if not player.Parent then
		return
	end
	if not ok then
		player:Kick(self.opts.KickMessage)
		return
	end
	local data = result or {}
	Util.Reconcile(data, self.template(player), self.opts.Freeform) -- a brand-new player is just a fully "missing" save
	self.profiles[player] = data
	self:_syncAttributes(player, data)
	self._loaded:Fire(player, data)
end

function Profiles:Get(player)
	return self.profiles[player]
end

function Profiles:All()
	return self.profiles
end

-- Yields until the profile is ready (or the player leaves / timeout).
function Profiles:WaitForData(player, timeout: number?)
	local deadline = os.clock() + (timeout or 30)
	while not self.profiles[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return self.profiles[player]
end

-- Adds (or, with a negative amount, spends) a whole number of a known currency. False if refused.
function Profiles:AddCurrency(player, name: string, amount: number): boolean
	local data = self.profiles[player]
	local wallet = data and data[self.opts.CurrenciesKey]
	if not wallet or wallet[name] == nil then
		return false
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount % 1 ~= 0 then
		return false
	end
	local newValue = wallet[name] + amount
	if newValue < 0 then
		return false -- can't spend what you don't have
	end
	wallet[name] = newValue
	if self.opts.SyncAttributes then
		player:SetAttribute(name, newValue)
	end
	return true
end

function Profiles:AddItem(player, itemId: string, count: number): boolean
	local data = self.profiles[player]
	local inventory = data and data[self.opts.InventoryKey]
	if not inventory or count % 1 ~= 0 or count <= 0 then
		return false
	end
	inventory[itemId] = (inventory[itemId] or 0) + count
	return true
end

function Profiles:Save(player): boolean
	local data = self.profiles[player]
	if not data then
		return false
	end
	data.LastSeen = os.time()
	local ok = self:_withRetry(function()
		self.store:UpdateAsync(self.opts.Key(player), function()
			return data
		end)
	end)
	return ok
end

function Profiles:Start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:_load(player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_load(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self:Save(player)
		self.profiles[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(self.opts.AutosaveSeconds)
			for player in self.profiles do
				task.spawn(function()
					self:Save(player)
				end)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in self.profiles do
			pending += 1
			task.spawn(function()
				self:Save(player)
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
	end)
end

return Profiles

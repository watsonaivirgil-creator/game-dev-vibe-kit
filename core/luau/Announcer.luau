--!nonstrict
-- Server-wide banners that can't be spammed: one banner per interval from a short queue (newest win), plus a
-- per-player cooldown per kind so two accounts can't pass an item back and forth to flood everyone's screen.
-- You decide WHAT is announce-worthy and build the text; this decides WHEN it may be shown.
--
--   local announcer = Announcer.new({
--       IntervalSeconds = 2,            -- at most one banner per interval
--       MaxQueue = 10,                  -- a burst keeps only the newest this-many
--       PlayerCooldownSeconds = 30,     -- same player + same kind: at most once per cooldown
--       Broadcast = function(payload) remoteEvent:FireAllClients(payload) end,
--   })
--   announcer:Start()
--   announcer:TryAnnounce("RareDrop", { player }, { Kind = "RareDrop", Text = "..." })  -- false if on cooldown
--
-- Security note: build banner text from your own data. The only player-controlled text should be the player name.

local Announcer = {}
Announcer.__index = Announcer

function Announcer.new(opts)
	local self = setmetatable({}, Announcer)
	self.interval = opts.IntervalSeconds or 2
	self.maxQueue = opts.MaxQueue or 10
	self.cooldown = opts.PlayerCooldownSeconds or 30
	self.broadcast = opts.Broadcast or function() end
	self.clock = opts.Clock or os.clock
	self.queue = {}
	self.lastByKey = {} -- ["RareDrop:123"] = clock time
	return self
end

function Announcer:SetBroadcaster(fn)
	self.broadcast = fn or function() end
end

-- Queue a banner with no cooldown check (drop-oldest when the queue is full: stale news isn't worth showing).
function Announcer:Announce(payload)
	table.insert(self.queue, payload)
	while #self.queue > self.maxQueue do
		table.remove(self.queue, 1)
	end
end

-- True if ANY of the players announced this kind within the cooldown.
function Announcer:OnCooldown(kind: string, players): boolean
	local now = self.clock()
	for _, player in players do
		local last = self.lastByKey[kind .. ":" .. player.UserId]
		if last and now - last < self.cooldown then
			return true
		end
	end
	return false
end

function Announcer:Stamp(kind: string, players)
	local now = self.clock()
	for _, player in players do
		self.lastByKey[kind .. ":" .. player.UserId] = now
	end
end

-- Cooldown check + stamp + queue in one call. Returns false (and queues nothing) when on cooldown.
function Announcer:TryAnnounce(kind: string, players, payload): boolean
	if self:OnCooldown(kind, players) then
		return false
	end
	self:Stamp(kind, players)
	self:Announce(payload)
	return true
end

-- Show at most one queued banner now. Returns it, or nil if the queue was empty.
function Announcer:Pump()
	local payload = table.remove(self.queue, 1)
	if payload then
		self.broadcast(payload)
	end
	return payload
end

function Announcer:Start()
	task.spawn(function()
		while true do
			task.wait(self.interval)
			self:Pump()
		end
	end)
end

return Announcer

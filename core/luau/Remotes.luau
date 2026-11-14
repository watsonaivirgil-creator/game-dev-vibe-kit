--!nonstrict
-- Remote creation with the safety every game needs: per-player rate limiting and error containment.
--
--   local remotes = Remotes.new({ MinInterval = 0.15 })        -- creates ReplicatedStorage.Remotes
--   remotes:Function("ClaimDaily", function(player, ...) return { ok = true } end)
--   local pushToClient = remotes:Event("RewardNotify")          -- a RemoteEvent for server -> client pushes
--
-- Every Function remote:
--   * refuses a player calling faster than MinInterval with { ok = false, err = "Too fast" },
--   * catches errors in your handler: the client gets { ok = false, err = "Server error" } (instead of nil) and the
--     error goes to the output with the remote's name,
--   * forgets a player's timer when they leave.
-- Convention: handlers return { ok = boolean, err = string?, ... }. NEVER trust arguments: validate them in the
-- handler (the services in this kit already do).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
Remotes.__index = Remotes

function Remotes.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Remotes)
	self.minInterval = opts.MinInterval or 0.15
	self.clock = opts.Clock or os.clock
	if opts.Folder then
		self.folder = opts.Folder
	else
		self.folder = Instance.new("Folder")
		self.folder.Name = opts.Name or "Remotes"
		self.folder.Parent = opts.Parent or ReplicatedStorage
	end
	return self
end

function Remotes:Function(name: string, handler)
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = self.folder

	local lastCall = {}
	Players.PlayerRemoving:Connect(function(player)
		lastCall[player] = nil
	end)

	remote.OnServerInvoke = function(player, ...)
		local now = self.clock()
		if lastCall[player] and now - lastCall[player] < self.minInterval then
			return { ok = false, err = "Too fast" }
		end
		lastCall[player] = now
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(("[Remotes] %s failed: %s"):format(name, tostring(result)))
			return { ok = false, err = "Server error" }
		end
		return result
	end
	return remote
end

-- Creates a RemoteEvent and returns it (use :FireClient / :FireAllClients).
function Remotes:Event(name: string)
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = self.folder
	return remote
end

return Remotes

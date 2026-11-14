--!strict
local RemoteGuard = {}
RemoteGuard.__index = RemoteGuard

export type RateLimiter = {
	check: (self: RateLimiter, userId: number) -> boolean,
	clear: (self: RateLimiter, userId: number) -> (),
}

--- Creates a per-player cooldown tracker for server RemoteEvents/RemoteFunctions.
function RemoteGuard.newRateLimiter(cooldownSeconds: number): RateLimiter
	local lastCallByUser: { [number]: number } = {}

	local self = {}

	function self:check(userId: number): boolean
		local now = os.clock()
		local last = lastCallByUser[userId]
		if last and (now - last) < cooldownSeconds then
			return false
		end
		lastCallByUser[userId] = now
		return true
	end

	function self:clear(userId: number)
		lastCallByUser[userId] = nil
	end

	return (self :: any) :: RateLimiter
end

--- Safely gets or creates a RemoteEvent inside a target folder.
function RemoteGuard.getOrCreateEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

--- Safely gets or creates a RemoteFunction inside a target folder.
function RemoteGuard.getOrCreateFunction(parent: Instance, name: string): RemoteFunction
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

return RemoteGuard

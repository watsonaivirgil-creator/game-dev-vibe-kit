--!nonstrict
-- Small helpers every module needs. Plain-data only: no Roblox instances.

local Util = {}

-- Deep copy of a plain data table (the kind a profile holds). Not for tables with cycles or metatables.
function Util.DeepCopy(t)
	local out = {}
	for k, v in t do
		out[k] = type(v) == "table" and Util.DeepCopy(v) or v
	end
	return out
end

-- Fill in keys missing from `data` using `template`, recursively, without touching anything that exists.
-- Tables listed in `freeform` (by key) hold player data (item ids...), not schema, and are never merged into.
-- Lets a game add fields to a saved profile without writing migrations.
function Util.Reconcile(data, template, freeform)
	for k, v in template do
		if data[k] == nil then
			data[k] = type(v) == "table" and Util.DeepCopy(v) or v
		elseif type(v) == "table" and type(data[k]) == "table" and next(v) ~= nil and not (freeform and freeform[k]) then
			Util.Reconcile(data[k], v, freeform)
		end
	end
end

-- Number of keys in a table (works for non-array tables).
function Util.CountKeys(t): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- For a map of { [id] = timestamp }: drop the oldest entries until at most `max` remain.
-- (Receipt histories, cooldown tables and the like.)
function Util.TrimOldest(map, max: number)
	local count = Util.CountKeys(map)
	while count > max do
		local oldestId, oldestAt = nil, math.huge
		for id, at in map do
			if at < oldestAt then
				oldestId, oldestAt = id, at
			end
		end
		if oldestId == nil then
			return
		end
		map[oldestId] = nil
		count -= 1
	end
end

return Util

--!nonstrict
-- Pure drop-rate math: no Roblox APIs, no state. The server rolls with it and the client uses it to
-- display exact odds (Roblox requires odds disclosure for paid random items).

local GachaMath = {}

-- ladder: array of { Rarity: string, Weight: number }, most common first.
-- Luck multiplies every rung except the first; it is clamped to [1, maxLuck] so it can only help.
-- Returns an array of { Rarity, Chance } whose chances sum to 1.
function GachaMath.ComputeOdds(ladder, luck, maxLuck)
	if luck == nil or luck ~= luck then
		luck = 1
	end
	luck = math.clamp(luck, 1, math.max(1, maxLuck or 1))

	local weights, total = {}, 0
	for i, rung in ladder do
		local w = rung.Weight * (i == 1 and 1 or luck)
		weights[i] = w
		total += w
	end

	local odds = {}
	for i, rung in ladder do
		odds[i] = { Rarity = rung.Rarity, Chance = weights[i] / total }
	end
	return odds
end

-- Picks a rung index for r in [0, 1). fromIndex/toIndex restrict the eligible rungs (inclusive) and
-- renormalise their chances; pity uses this to force a specific rung.
function GachaMath.Pick(odds, r, fromIndex, toIndex)
	fromIndex = fromIndex or 1
	toIndex = toIndex or #odds
	local total = 0
	for i = fromIndex, toIndex do
		total += odds[i].Chance
	end
	local target = r * total
	local acc = 0
	for i = fromIndex, toIndex do
		acc += odds[i].Chance
		if target < acc then
			return i
		end
	end
	return toIndex
end

return GachaMath

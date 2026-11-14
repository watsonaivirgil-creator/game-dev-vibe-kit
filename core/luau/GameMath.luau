--!strict
local GameMath = {}

export type WeightedItem<T> = {
	item: T,
	weight: number,
}

--- Frame-rate independent lerp for smooth camera, UI, or CFrame damping.
function GameMath.damp(current: number, target: number, lambda: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-lambda * dt))
end

--- Rolls a single item from a weighted loot/gacha table.
function GameMath.rollWeighted<T>(pool: { WeightedItem<T> }, rng: Random?): T?
	local random = rng or Random.new()
	local totalWeight = 0
	for _, entry in ipairs(pool) do
		if entry.weight > 0 then
			totalWeight += entry.weight
		end
	end

	if totalWeight <= 0 then
		return nil
	end

	local roll = random:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, entry in ipairs(pool) do
		if entry.weight > 0 then
			cumulative += entry.weight
			if roll <= cumulative then
				return entry.item
			end
		end
	end

	return pool[#pool].item
end

--- Calculates soft-pity boosted drop rate (0.0 to 1.0) once pulls pass softPityStart.
function GameMath.calculatePityRate(
	pullsSinceHit: number,
	baseRate: number,
	softPityStart: number,
	hardPityMax: number
): number
	if pullsSinceHit >= hardPityMax - 1 then
		return 1.0
	end
	if pullsSinceHit < softPityStart then
		return baseRate
	end

	local stepsIntoSoft = pullsSinceHit - softPityStart + 1
	local totalSoftSteps = math.max(1, hardPityMax - softPityStart)
	local ramp = (1.0 - baseRate) * (stepsIntoSoft / totalSoftSteps)
	return math.clamp(baseRate + ramp, baseRate, 1.0)
end

--- Calculates XP required to reach the next level using a standard exponential RPG curve.
function GameMath.xpForLevel(level: number, baseXp: number?, exponent: number?): number
	local base = baseXp or 100
	local exp = exponent or 1.5
	return math.floor(base * (math.max(1, level) ^ exp))
end

return GameMath

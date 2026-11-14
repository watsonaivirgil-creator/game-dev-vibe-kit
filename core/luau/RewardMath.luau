--!nonstrict
-- Pure helpers for the free-Gem system: UTC day/week indexes, the login ladder and deterministic quest picks.
-- No game state here, so every rule can be tested with plain numbers.

local RewardMath = {}

local SECONDS_PER_DAY = 86400

-- Whole UTC days since the Unix epoch. Everyone's "day" rolls over at the same moment (00:00 UTC).
function RewardMath.DayIndex(t: number): number
	return math.floor(t / SECONDS_PER_DAY)
end

-- Weeks run Monday..Sunday (UTC). Day 0 (1 Jan 1970) was a Thursday, so Monday is day 4, 11, 18...
function RewardMath.WeekIndex(day: number): number
	return math.floor((day + 3) / 7)
end

function RewardMath.WeekStartDay(week: number): number
	return week * 7 - 3
end

-- Streak day (1-based) -> (base Gems from the repeating cycle, bonus Gems if it is a milestone day).
function RewardMath.LoginReward(loginCfg, streak: number): (number, number)
	local cycle = loginCfg.Cycle
	local base = cycle[((streak - 1) % #cycle) + 1]
	return base, loginCfg.Milestones[streak] or 0
end

-- xorshift32: tiny, deterministic and identical on every server, so all servers agree on today's quests.
local function makeRng(seed: number)
	local s = (seed * 2654435761) % 4294967296
	if s == 0 then
		s = 1
	end
	return function()
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		return s
	end
end

-- Choose `count` quests from the pool for this seed (a day or week index). Never two quests on the same
-- Stat, so "work 3 shifts" and "work 8 shifts" can't both appear. Returns fewer if the pool runs out.
function RewardMath.PickQuests(pool, count: number, seed: number)
	local nextRandom = makeRng(seed)
	local candidates = table.clone(pool)
	local picked, usedStats = {}, {}
	while #picked < count and #candidates > 0 do
		local i = (nextRandom() % #candidates) + 1
		local quest = table.remove(candidates, i)
		if not usedStats[quest.Stat] then
			usedStats[quest.Stat] = true
			table.insert(picked, quest)
		end
	end
	return picked
end

return RewardMath

--!nonstrict
-- Gacha pity counters ("a guaranteed rare after N dry pulls") with exact-rung guarantees, plus a simulator for tuning.
-- Pure: no Roblox APIs. Works with GachaMath.ComputeOdds ladders (most common rung first, rarest last).
--
--   local state = Pity.NewState()                          -- store one per player per table: { Pulls, SinceHigh, SinceTop }
--   local index, pity = Pity.Pull(state, def, odds, random)
--       def  = { PityHigh = 40, PityTop = 300 }
--       odds = GachaMath.ComputeOdds(ladder, luck, maxLuck)
--       random() -> number in [0, 1)
--       pity = nil | "High" | "Top"   which guarantee (if any) decided this pull
--
-- Why "exact rung": a guarantee forces ONE rung (second-highest after PityHigh dry pulls, highest after PityTop),
-- never "that rung or better". Letting the top rung ride along with the lower guarantee roughly doubles its
-- real-world rate, so the advertised odds would be a lie. (Found and fixed in the first game; kept here.)
-- Pity makes real rates higher than the base odds: use Pity.Simulate to measure them and disclose both.

local GachaMath = require(script.Parent.GachaMath)

local Pity = {}

function Pity.NewState()
	return { Pulls = 0, SinceHigh = 0, SinceTop = 0 }
end

function Pity.Pull(state, def, odds, random)
	local top = #odds
	local forced, label = nil, nil
	if state.SinceTop + 1 >= def.PityTop then
		forced, label = top, "Top"
	elseif state.SinceHigh + 1 >= def.PityHigh then
		forced, label = top - 1, "High"
	end
	local index = GachaMath.Pick(odds, random(), forced, forced)
	state.Pulls += 1
	state.SinceTop = index == top and 0 or state.SinceTop + 1
	state.SinceHigh = index >= top - 1 and 0 or state.SinceHigh + 1
	return index, label
end

-- Monte-Carlo the real per-rung rates including pity: returns { counts = {n per rung}, rates = {fraction per rung} }.
-- Use it when tuning PityHigh / PityTop and when writing the odds disclosure.
function Pity.Simulate(odds, def, pulls: number, random)
	local counts = {}
	for i = 1, #odds do
		counts[i] = 0
	end
	local state = Pity.NewState()
	for _ = 1, pulls do
		local index = Pity.Pull(state, def, odds, random)
		counts[index] += 1
	end
	local rates = {}
	for i = 1, #odds do
		rates[i] = counts[i] / pulls
	end
	return { counts = counts, rates = rates }
end

return Pity

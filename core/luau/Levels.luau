--!nonstrict
-- XP -> level -> stage progression with optional prestige ("rebirth"). Pure data in, data out: no Roblox APIs.
--
--   local levels = Levels.new({
--       XPBase = 50, XPExponent = 0.5,                      -- XP to leave level L = floor(XPBase * L ^ XPExponent)
--       Stages = { "Novice", "Master", "Legend" },           -- in order
--       LevelsPerStage = { Novice = 10, Master = 25, Legend = 50 },
--   })
--   local state = { Level = 1, XP = 0, Stage = "Novice", Rebirths = 0 }   -- store this in the profile
--   local gained = levels:AddXP(state, 120)                 -- mutates state, returns levels gained
--   if levels:CanPrestige(state) then levels:Prestige(state) end
--
-- Hardening (tested): NaN / negative / non-number XP is ignored (NaN would poison a saved profile forever),
-- XP is dropped at the level cap, and one big XP award can cross many levels in a single call.

local Levels = {}
Levels.__index = Levels

function Levels.new(cfg)
	assert(type(cfg) == "table" and type(cfg.Stages) == "table" and #cfg.Stages > 0, "Levels.new: Stages required")
	local self = setmetatable({}, Levels)
	self.cfg = cfg
	local total = 0
	for _, stage in cfg.Stages do
		assert(cfg.LevelsPerStage[stage], "Levels.new: LevelsPerStage missing " .. tostring(stage))
		total += cfg.LevelsPerStage[stage]
	end
	self._max = total
	return self
end

function Levels:MaxLevel(): number
	return self._max
end

function Levels:StageForLevel(level: number): string
	local cumulative = 0
	for _, stage in self.cfg.Stages do
		cumulative += self.cfg.LevelsPerStage[stage]
		if level <= cumulative then
			return stage
		end
	end
	return self.cfg.Stages[#self.cfg.Stages]
end

-- First level of a stage (1 for the first stage). Useful for stage-boundary achievements.
function Levels:FirstLevelOf(stage: string): number?
	local cumulative = 0
	for _, name in self.cfg.Stages do
		if name == stage then
			return cumulative + 1
		end
		cumulative += self.cfg.LevelsPerStage[name]
	end
	return nil
end

function Levels:XPToNext(level: number): number
	return math.floor(self.cfg.XPBase * level ^ self.cfg.XPExponent)
end

function Levels:AddXP(state, amount): number
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local before = state.Level
	state.XP += amount
	while state.Level < self._max and state.XP >= self:XPToNext(state.Level) do
		state.XP -= self:XPToNext(state.Level)
		state.Level += 1
	end
	if state.Level >= self._max then
		state.XP = 0
	end
	state.Stage = self:StageForLevel(state.Level)
	return state.Level - before
end

function Levels:CanPrestige(state): boolean
	return state.Level >= self._max
end

-- Back to level 1 with one more Rebirths. False (nothing changed) if the cap hasn't been reached.
function Levels:Prestige(state): boolean
	if not self:CanPrestige(state) then
		return false
	end
	state.Rebirths += 1
	state.Level = 1
	state.XP = 0
	state.Stage = self.cfg.Stages[1]
	return true
end

return Levels

--!nonstrict
-- Free-currency reward engine: daily login streaks, "first activity of the day" bonus, daily and weekly quests,
-- and one-time achievements, behind one validated, capped door (Grant). Currency-neutral: it pays whatever
-- currency you name ("Gems", "Stars", "Coins"...), and knows nothing about shifts, furniture or any other game system.
--
--   local rewards = Rewards.new({
--       Config = { ... see CONFIG below ... },
--       GetProfile = function(player) return profileTable end,         -- your saved-data table for that player
--       AddCurrency = function(player, name, amount) return true end,  -- your currency door (must refuse bad input)
--   })
--   rewards:Record(player, "Shifts", 1)          -- your game reports what happened (counter stats)
--   rewards:SetMax(player, "BestLevel", 12)      -- ...or a high-water mark (never decreases)
--   rewards:MarkActive(player)                   -- ...or "the player did their thing today"
--   rewards:ClaimDailyLogin(player)              -- wire to a button
--   rewards:GetOverview(player)                  -- wire to your UI
--
-- Guarantees (all tested):
--   * Everything is paid through Grant: validated input, per-UTC-day cap, logged, event + notifier fired.
--   * A reward is never paid twice and never silently lost: paid flags are set BEFORE the grant and rolled back if
--     the cap refuses it, so the reward stays unpaid and settles on a later call.
--   * Days roll over at 00:00 UTC for everyone, weeks on Monday. Quests come from a deterministic seed (same on
--     every server), never two on the same stat.
--   * State lives in profile[StateKey] and is created / upgraded lazily, so no changes to your profile template.
--
-- CONFIG (all optional except the data you want):
--   Currency          (required) "Gems"  name passed to AddCurrency
--   DailyCap          1500              hard ceiling on currency granted per UTC day, across ALL sources
--   MaxLog            30                recent grants remembered per player
--   ActiveDayReward   5                 paid on the first MarkActive of each UTC day (0 disables the payout)
--   ActiveDayStat     "Days"            stat incremented on each active day
--   ActiveDayReason   "active_day"      reason string logged for that payout
--   DailyQuestCount   3, WeeklyQuestCount 2, DailyBonusReward 15 (all dailies done; 0 disables)
--   DailyLogin        { Cycle = {10,10,15,...}, Milestones = { [7] = 40 } }
--   Quests            { Daily = { {Id, Stat, Target, Reward, Name} }, Weekly = { ... } }
--   Achievements      { {Id, Stat, Target, Reward, Name} }   one-time, compared with the lifetime stat
-- Reasons used by the engine itself: "login", "daily_bonus", ActiveDayReason, and each quest / achievement Id.

local Util = require(script.Parent.Util)
local RewardMath = require(script.Parent.RewardMath)

local Rewards = {}
Rewards.__index = Rewards

local WEEKLY_SEED_OFFSET = 1000000 -- keeps weekly picks independent of daily picks

local function newState()
	return {
		Stats = {}, -- lifetime counters by stat name
		Login = { LastDay = 0, Streak = 0, Best = 0 },
		ActiveDay = { LastDay = 0 },
		Daily = { Day = 0, Progress = {}, Claimed = {}, BonusClaimed = false },
		Weekly = { Week = 0, Progress = {}, Claimed = {} },
		Achievements = {}, -- [id] = true once paid
		Earned = { Day = 0, Total = 0 }, -- currency granted today (the cap window)
		Log = {}, -- recent grants, newest last: { T, Amount, Reason }
	}
end

function Rewards.new(opts)
	assert(type(opts) == "table", "Rewards.new needs an options table")
	assert(type(opts.GetProfile) == "function", "Rewards.new: GetProfile is required")
	assert(type(opts.AddCurrency) == "function", "Rewards.new: AddCurrency is required")
	local cfg = opts.Config or {}
	assert(type(cfg.Currency) == "string", "Rewards.new: Config.Currency is required (e.g. \"Gems\")")
	local self = setmetatable({}, Rewards)
	self.getProfile = opts.GetProfile
	self.addCurrency = opts.AddCurrency
	self.getBalance = opts.GetBalance
	self.now = opts.Now or os.time
	self.stateKey = opts.StateKey or "Rewards"
	self.cfg = {
		Currency = cfg.Currency,
		DailyCap = cfg.DailyCap or math.huge,
		MaxLog = cfg.MaxLog or 30,
		ActiveDayReward = cfg.ActiveDayReward or 0,
		ActiveDayStat = cfg.ActiveDayStat or "Days",
		ActiveDayReason = cfg.ActiveDayReason or "active_day",
		DailyQuestCount = cfg.DailyQuestCount or 0,
		WeeklyQuestCount = cfg.WeeklyQuestCount or 0,
		DailyBonusReward = cfg.DailyBonusReward or 0,
		DailyLogin = cfg.DailyLogin or { Cycle = { 0 }, Milestones = {} },
		Quests = cfg.Quests or { Daily = {}, Weekly = {} },
		Achievements = cfg.Achievements or {},
	}
	self.loginEnabled = cfg.DailyLogin ~= nil -- a game without a login ladder just doesn't configure one
	assert(#self.cfg.DailyLogin.Cycle > 0, "Rewards: DailyLogin.Cycle must have at least one entry")

	local granted = Instance.new("BindableEvent")
	-- Fires (player, amount, reason) after every successful grant. Telemetry listens here.
	self.Granted = granted.Event
	self._granted = granted
	self.notifier = function(_player, _payload) end
	return self
end

-- fn(player, payload): payload = { Amount, Reason, Balance, Currency, [CurrencyName] = Balance }. Wire to a RemoteEvent.
function Rewards:SetNotifier(fn)
	self.notifier = fn or function() end
end

function Rewards:_today(): number
	return RewardMath.DayIndex(self.now())
end

-- The player's reward state (created or upgraded on first use). nil when no profile is loaded.
function Rewards:GetState(player)
	local profile = self.getProfile(player)
	if not profile then
		return nil
	end
	local state = profile[self.stateKey]
	if state == nil then
		state = newState()
		profile[self.stateKey] = state
	else
		Util.Reconcile(state, newState())
	end
	return state
end

-- Start a fresh day / week / cap window when the calendar has moved on.
function Rewards:_rollover(state)
	local day = self:_today()
	if state.Daily.Day ~= day then
		state.Daily = { Day = day, Progress = {}, Claimed = {}, BonusClaimed = false }
	end
	local week = RewardMath.WeekIndex(day)
	if state.Weekly.Week ~= week then
		state.Weekly = { Week = week, Progress = {}, Claimed = {} }
	end
	if state.Earned.Day ~= day then
		state.Earned = { Day = day, Total = 0 }
	end
end

function Rewards:_dailyQuests(state)
	return RewardMath.PickQuests(self.cfg.Quests.Daily, self.cfg.DailyQuestCount, state.Daily.Day)
end

function Rewards:_weeklyQuests(state)
	return RewardMath.PickQuests(self.cfg.Quests.Weekly, self.cfg.WeeklyQuestCount, state.Weekly.Week + WEEKLY_SEED_OFFSET)
end

----------------------------------------------------------------------
-- the one door
----------------------------------------------------------------------
function Rewards:Grant(player, amount, reason): (boolean, string?)
	local state = self:GetState(player)
	if not state then
		return false, "Data not loaded"
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 or amount % 1 ~= 0 or typeof(reason) ~= "string" then
		return false, "Bad grant"
	end
	self:_rollover(state)
	if state.Earned.Total + amount > self.cfg.DailyCap then
		return false, "Daily limit reached"
	end
	if not self.addCurrency(player, self.cfg.Currency, amount) then
		return false, "Bad grant"
	end
	state.Earned.Total += amount
	table.insert(state.Log, { T = self.now(), Amount = amount, Reason = reason })
	while #state.Log > self.cfg.MaxLog do
		table.remove(state.Log, 1)
	end
	self._granted:Fire(player, amount, reason)
	local balance = self:_balance(player)
	local payload = { Amount = amount, Reason = reason, Balance = balance, Currency = self.cfg.Currency }
	payload[self.cfg.Currency] = balance
	self.notifier(player, payload)
	return true
end

function Rewards:_balance(player)
	if self.getBalance then
		return self.getBalance(player, self.cfg.Currency)
	end
	local profile = self.getProfile(player)
	return profile and profile.Currencies and profile.Currencies[self.cfg.Currency]
end

----------------------------------------------------------------------
-- settling
----------------------------------------------------------------------
-- Pay every finished, unpaid quest in a bucket ({ Progress, Claimed }). False if the cap stopped us.
function Rewards:_settleQuests(player, quests, bucket): boolean
	for _, quest in quests do
		if not bucket.Claimed[quest.Id] and (bucket.Progress[quest.Stat] or 0) >= quest.Target then
			bucket.Claimed[quest.Id] = true
			if not self:Grant(player, quest.Reward, quest.Id) then
				bucket.Claimed[quest.Id] = nil
				return false
			end
		end
	end
	return true
end

local function allClaimed(quests, bucket): boolean
	for _, quest in quests do
		if not bucket.Claimed[quest.Id] then
			return false
		end
	end
	return #quests > 0
end

-- Pays whatever became due. Idempotent: safe to call as often as you like.
function Rewards:Settle(player)
	local state = self:GetState(player)
	if not state then
		return
	end
	self:_rollover(state)

	local daily = self:_dailyQuests(state)
	if not self:_settleQuests(player, daily, state.Daily) then
		return
	end
	if self.cfg.DailyBonusReward > 0 and not state.Daily.BonusClaimed and allClaimed(daily, state.Daily) then
		state.Daily.BonusClaimed = true
		if not self:Grant(player, self.cfg.DailyBonusReward, "daily_bonus") then
			state.Daily.BonusClaimed = false
			return
		end
	end

	if not self:_settleQuests(player, self:_weeklyQuests(state), state.Weekly) then
		return
	end

	for _, achievement in self.cfg.Achievements do
		if not state.Achievements[achievement.Id] and (state.Stats[achievement.Stat] or 0) >= achievement.Target then
			state.Achievements[achievement.Id] = true
			if not self:Grant(player, achievement.Reward, achievement.Id) then
				state.Achievements[achievement.Id] = nil
				return
			end
		end
	end
end

----------------------------------------------------------------------
-- reporting what happened
----------------------------------------------------------------------
-- Counter stat: adds to the lifetime total and to today's and this week's quest progress.
function Rewards:Record(player, stat, amount)
	local state = self:GetState(player)
	if not state or typeof(stat) ~= "string" or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	self:_rollover(state)
	state.Stats[stat] = (state.Stats[stat] or 0) + amount
	state.Daily.Progress[stat] = (state.Daily.Progress[stat] or 0) + amount
	state.Weekly.Progress[stat] = (state.Weekly.Progress[stat] or 0) + amount
	self:Settle(player)
end

-- High-water stat (best level, plot size...): lifetime only, never goes down, no quest progress.
function Rewards:SetMax(player, stat, value)
	local state = self:GetState(player)
	if not state or typeof(stat) ~= "string" or typeof(value) ~= "number" or value ~= value then
		return
	end
	if value > (state.Stats[stat] or 0) then
		state.Stats[stat] = value
	end
	self:Settle(player)
end

-- "The player did their thing today" (worked a shift, played a round...). The first call each UTC day pays
-- ActiveDayReward and counts one ActiveDayStat. Returns true when this call was the day's first.
function Rewards:MarkActive(player): boolean
	local state = self:GetState(player)
	if not state then
		return false
	end
	self:_rollover(state)
	local day = self:_today()
	if state.ActiveDay.LastDay == day then
		return false
	end
	state.ActiveDay.LastDay = day
	if self.cfg.ActiveDayReward > 0 then
		self:Grant(player, self.cfg.ActiveDayReward, self.cfg.ActiveDayReason) -- a cap refusal just forfeits this small bonus
	end
	self:Record(player, self.cfg.ActiveDayStat, 1)
	return true
end

----------------------------------------------------------------------
-- daily login
----------------------------------------------------------------------
-- Explicit claim (a button), once per UTC day. Missing a day restarts the streak at day 1.
function Rewards:ClaimDailyLogin(player)
	if not self.loginEnabled then
		return nil, "Daily login is not enabled"
	end
	local state = self:GetState(player)
	if not state then
		return nil, "Data not loaded"
	end
	self:_rollover(state)
	local day = self:_today()
	local login = state.Login
	if login.LastDay >= day then
		return nil, "Already claimed today"
	end
	local before = { LastDay = login.LastDay, Streak = login.Streak, Best = login.Best }
	local streak = (login.LastDay == day - 1) and login.Streak + 1 or 1
	local base, milestone = RewardMath.LoginReward(self.cfg.DailyLogin, streak)
	login.LastDay, login.Streak, login.Best = day, streak, math.max(login.Best, streak)
	local ok, why = self:Grant(player, base + milestone, "login")
	if not ok then
		login.LastDay, login.Streak, login.Best = before.LastDay, before.Streak, before.Best
		return nil, why
	end
	self:Record(player, "Login", 1)
	local result = { Streak = streak, Amount = base + milestone, Base = base, Milestone = milestone }
	result[self.cfg.Currency] = base + milestone
	return result
end

----------------------------------------------------------------------
-- what the client shows
----------------------------------------------------------------------
-- Each entry carries its payout as Reward and also under the currency's own name (Gems = 10, Stars = 10...).
local function entryFor(def, progress, done, currency)
	local entry = {
		Id = def.Id,
		Stat = def.Stat,
		Name = def.Name,
		Target = def.Target,
		Reward = def.Reward,
		Progress = math.min(progress, def.Target),
		Done = done,
	}
	entry[currency] = def.Reward
	return entry
end

function Rewards:_describe(quests, bucket)
	local out = {}
	for _, quest in quests do
		table.insert(out, entryFor(quest, bucket.Progress[quest.Stat] or 0, bucket.Claimed[quest.Id] == true, self.cfg.Currency))
	end
	return out
end

function Rewards:GetOverview(player)
	local state = self:GetState(player)
	if not state then
		return nil, "Data not loaded"
	end
	self:_rollover(state)
	local day = self:_today()
	local login = state.Login
	local liveStreak = login.LastDay >= day - 1 and login.Streak or 0
	local nextStreak = (login.LastDay == day - 1 or login.LastDay == day) and login.Streak + 1 or 1
	local base, milestone = RewardMath.LoginReward(self.cfg.DailyLogin, nextStreak)

	local achievements = {}
	for _, a in self.cfg.Achievements do
		table.insert(achievements, entryFor(a, state.Stats[a.Stat] or 0, state.Achievements[a.Id] == true, self.cfg.Currency))
	end

	return {
		Currency = self.cfg.Currency,
		Login = {
			CanClaim = self.loginEnabled and login.LastDay < day,
			Streak = liveStreak,
			Best = login.Best,
			NextStreak = nextStreak,
			NextReward = base + milestone,
			Cycle = self.cfg.DailyLogin.Cycle,
		},
		ActiveDayReward = self.cfg.ActiveDayReward,
		ActiveToday = state.ActiveDay.LastDay == day,
		Daily = {
			Quests = self:_describe(self:_dailyQuests(state), state.Daily),
			BonusReward = self.cfg.DailyBonusReward,
			BonusClaimed = state.Daily.BonusClaimed,
		},
		Weekly = { Quests = self:_describe(self:_weeklyQuests(state), state.Weekly) },
		Achievements = achievements,
		EarnedToday = state.Earned.Total,
		DailyCap = self.cfg.DailyCap,
		Recent = table.clone(state.Log),
	}
end

return Rewards

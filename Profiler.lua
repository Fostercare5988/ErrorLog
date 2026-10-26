-- Stutter finder. While on (/lag on) every OnEvent,
-- OnUpdate, OnShow and OnHide script an addon sets, and every C_Timer
-- callback, is timed and its new Lua memory counted, for the addon that set it.
-- A frame that takes longer than HITCH_MS is saved with the addons that ran
-- during it, so you can see whether a stutter was addon code or the game itself.
--   /lag          open the report (also the Stutters button in /err)
--   /lag on|off   start or stop profiling; reloads the UI to (un)hook
--   /lag clear    forget what was caught so far
local EL = ErrorLog
local clock = debugprofilestop
if not EL or not clock then return end

local HITCH_MS = 100    -- a gap between frames this long is a stutter
local SLOW_MS = 5       -- one handler call this long gets listed
local MAX_HITCHES = 40
local MAX_SLOW = 200
local WRAPPED = { OnEvent = true, OnUpdate = true, OnShow = true, OnHide = true }

local db
local active
local startedAt, quietUntil = 0, 0
local lastHitchAt = 0 -- GetTime() of the last slow frame this session

-- Lua memory, read every frame. A sudden drop means the garbage collector ran
-- in that frame: it pauses everything, usually outside any addon handler, so
-- the handler timings cannot see it.
local GC_DROP_KB = 512
local lastKB, peakKB, grownKB = nil, 0, 0
local gcRuns, gcFreedKB, gcInHitches = 0, 0, 0
local function LuaKB()
	if gcinfo then return (gcinfo()) end
	return collectgarbage("count")
end
local depth = 0
-- Time since the last driver tick, per addon; reused to avoid garbage.
local used, calls, worst, worstLabel = {}, {}, {}, {}
local totals = {} -- addon -> ms this session
-- New Lua memory made inside each addon's handlers (KB this session). The
-- counter only grows between collections, so the rise across a call is what
-- it made; a fall means a collection ran inside that call (gcIn).
local made = {}
local gcIn
local origOf = setmetatable({}, { __mode = "k" }) -- wrapper -> original
local labelOf = setmetatable({}, { __mode = "k" }) -- original -> label

-- "Lifecycle.lua:60" and the addon folder, from the code that set the script.
-- A shared helper (HookScript and the like) is shown with its caller.
local function Origin()
	local stack = debugstack(2, 6, 0) or ""
	local addon, label
	for path, line in (string.gmatch or string.gfind)(stack, "AddOns\\([^:\n]+):(%d+)") do
		local _, _, folder, file = string.find(path, "^([^\\]+)\\(.+)$")
		if folder and folder ~= "!ErrorLog" then
			file = string.gsub(file, ".*\\", "")
			if not addon then
				addon, label = folder, file .. ":" .. line
			elseif folder == addon then
				label = label .. " < " .. file .. ":" .. line
				break
			end
		end
	end
	return addon, label
end

local function EventName(a, b)
	if type(a) == "string" then return a end
	if type(b) == "string" then return b end
	return event
end

local function NoteSlow(addon, label, script, ms, ev, collected)
	local key = addon .. " " .. label .. " " .. script .. " " .. (ev or "")
	local s = db.slow[key]
	if not s then
		if db.slowCount >= MAX_SLOW then return end
		db.slowCount = db.slowCount + 1
		s = { addon = addon, label = label, script = script, event = ev, count = 0, worst = 0, total = 0 }
		db.slow[key] = s
	end
	s.count = s.count + 1
	s.total = s.total + ms
	if ms > s.worst then s.worst = ms; s.last = date("%H:%M:%S"); s.gc = collected end
end

local function Wrap(fn, script)
	if type(fn) ~= "function" or origOf[fn] then return fn end
	local addon, label = Origin()
	if not addon then return fn end -- Blizzard's own code stays untouched
	labelOf[fn] = label
	local wrapper = function(...)
		depth = depth + 1
		local kb = LuaKB()
		local start = clock()
		fn(...)
		local ms = clock() - start
		kb = LuaKB() - kb
		depth = depth - 1
		-- Nested handlers (an OnShow inside an OnEvent) are already inside
		-- their parent's time and memory.
		if depth == 0 then
			used[addon] = (used[addon] or 0) + ms
			calls[addon] = (calls[addon] or 0) + 1
			if ms > (worst[addon] or 0) then
				worst[addon] = ms
				worstLabel[addon] = label .. " " .. script
			end
			if kb >= 0 then made[addon] = (made[addon] or 0) + kb else gcIn = addon end
		end
		if ms >= SLOW_MS then NoteSlow(addon, label, script, ms, script == "OnEvent" and EventName(...) or nil, kb < 0 or nil) end
	end
	origOf[wrapper] = fn
	return wrapper
end

local function HookWidgets()
	local done = {}
	for _, kind in ipairs({ "Frame", "Button", "CheckButton", "StatusBar", "Slider", "EditBox", "ScrollFrame",
		"ScrollingMessageFrame", "MessageFrame", "Model", "PlayerModel", "ColorSelect", "GameTooltip", "Cooldown" }) do
		local ok, sample = pcall(CreateFrame, kind)
		-- A new EditBox auto-focuses and would swallow every key press, so
		-- every sample is hidden and the edit box let go of the keyboard.
		if ok and sample then
			if sample.SetAutoFocus then sample:SetAutoFocus(false) end
			if sample.ClearFocus then sample:ClearFocus() end
			if sample.EnableKeyboard then sample:EnableKeyboard(false) end
			sample:Hide()
		end
		local mt = ok and sample and getmetatable(sample)
		local index = mt and type(mt.__index) == "table" and mt.__index
		if index and not done[index] and index.SetScript then
			done[index] = true
			local set, get = index.SetScript, index.GetScript
			index.SetScript = function(self, script, fn, a, b)
				if WRAPPED[script] then fn = Wrap(fn, script) end
				return set(self, script, fn, a, b)
			end
			-- Hand back the original so HookScript-style chaining and
			-- "is this my handler" checks behave as before.
			if get then
				index.GetScript = function(self, script)
					local fn = get(self, script)
					return fn and origOf[fn] or fn
				end
			end
		end
	end
end

local function HookTimers()
	if not C_Timer then return end
	for _, name in ipairs({ "After", "NewTimer", "NewTicker" }) do
		local real = C_Timer[name]
		if real then
			C_Timer[name] = function(delay, fn, a, b)
				return real(delay, Wrap(fn, "timer"), a, b)
			end
		end
	end
end

-- Runs once per frame: the gap since the last tick is the frame time, and
-- everything charged since then ran during that frame.
local driver = CreateFrame("Frame")
local function Tick(_, elapsed)
	elapsed = type(elapsed) == "number" and elapsed or arg1 or 0
	local now = GetTime()
	local ms = elapsed * 1000
	local lua = 0
	for addon, t in pairs(used) do
		lua = lua + t
		totals[addon] = (totals[addon] or 0) + t
	end
	local kb = LuaKB()
	local freed = 0
	if lastKB then
		if kb > lastKB then grownKB = grownKB + (kb - lastKB)
		elseif lastKB - kb >= GC_DROP_KB then
			freed = lastKB - kb
			gcRuns, gcFreedKB = gcRuns + 1, gcFreedKB + freed
		end
	end
	if kb > peakKB then peakKB = kb end
	lastKB = kb
	-- Loading screens and the first seconds after one are not stutters.
	if ms >= HITCH_MS and ms < 5000 and now >= quietUntil then
		local parts = {}
		for addon, t in pairs(used) do
			if t >= 0.5 then table.insert(parts, { addon = addon, ms = t, calls = calls[addon], worst = worstLabel[addon] }) end
		end
		table.sort(parts, function(x, y) return x.ms > y.ms end)
		local top = {}
		for i = 1, math.min(3, table.getn(parts)) do
			local p = parts[i]
			table.insert(top, string.format("%s %.1f ms over %d calls (worst %s)", p.addon, p.ms, p.calls, p.worst or "?"))
		end
		local zone = (GetRealZoneText and GetRealZoneText()) or "?"
		local h = db.hitches[1]
		-- Slow frames back to back (low FPS for a while, or the game in the
		-- background) become one run instead of pushing every stutter out.
		if h and now - lastHitchAt < 1 and h.zone == zone then
			h.frames = (h.frames or 1) + 1
			h.until_ = date("%H:%M:%S")
			if ms > h.ms then h.ms, h.lua, h.top = ms, lua, table.concat(top, "; ") end
			h.maxLua = math.max(h.maxLua or h.lua, lua)
			if freed > 0 then h.gc, h.gcIn = (h.gc or 0) + freed / 1024, gcIn or h.gcIn end
		else
			table.insert(db.hitches, 1, {
				time = date("%H:%M:%S"),
				zone = zone,
				ms = ms,
				lua = lua,
				combat = UnitAffectingCombat("player") and true or nil,
				group = (GetNumRaidMembers and GetNumRaidMembers() > 0 and "raid")
					or (GetNumPartyMembers and GetNumPartyMembers() > 0 and "party") or "solo",
				top = table.concat(top, "; "),
				gc = freed > 0 and freed / 1024 or nil,
				gcIn = freed > 0 and gcIn or nil,
				heap = kb / 1024,
			})
			while table.getn(db.hitches) > MAX_HITCHES do table.remove(db.hitches) end
		end
		lastHitchAt = now
		if freed > 0 then gcInHitches = gcInHitches + 1 end
	end
	for addon in pairs(used) do used[addon], calls[addon], worst[addon] = 0, 0, 0 end
	gcIn = nil
	depth = 0 -- a handler that errored never got to decrement it
end

local function Duration(seconds)
	seconds = math.floor(seconds)
	if seconds < 60 then return seconds .. "s" end
	return math.floor(seconds / 60) .. "m " .. (seconds - math.floor(seconds / 60) * 60) .. "s"
end

local function Report()
	if not active then
		return "Stutter profiler is off", "Type /lag on to start it.",
			"The profiler times every addon's event and update handlers. Turn it on, play until it\n"
			.. "stutters, then come back here."
	end
	local lines = {}
	local function add(text) table.insert(lines, text) end
	local running = GetTime() - startedAt

	add("STUTTERS (frames over " .. HITCH_MS .. " ms, newest first)")
	if table.getn(db.hitches) == 0 then add("  none yet") end
	for i = 1, table.getn(db.hitches) do
		local h = db.hitches[i]
		if h.frames and h.frames > 1 then
			add(string.format("%s-%s  %s, %s%s  %d slow frames in a row, worst %d ms (addons %.1f ms, at most %.1f)",
				h.time, h.until_ or "?", h.zone, h.group, h.combat and ", in combat" or "", h.frames, h.ms, h.lua,
				h.maxLua or h.lua))
		else
			add(string.format("%s  %s, %s%s  frame %d ms, addons %.1f ms", h.time, h.zone, h.group,
				h.combat and ", in combat" or "", h.ms, h.lua))
		end
		if h.gc then
			add(string.format("    garbage collection: freed %.1f MB (Lua memory %.0f MB)%s", h.gc, h.heap or 0,
				h.gcIn and (", started inside " .. h.gcIn) or ""))
		end
		if h.top ~= "" then add("    " .. h.top) end
	end
	add("If addons are only a small part of a stutter, the rest went to the game itself")
	add("(drawing, loading models, Lua garbage collection) or the server. A long run of")
	add("slow frames with almost no addon time is usually the game alt-tabbed or the GPU.")

	add("")
	add("LUA MEMORY since /reload")
	add(string.format("  now %.1f MB, peak %.1f MB, new memory used %.2f MB per second",
		(lastKB or 0) / 1024, peakKB / 1024, grownKB / 1024 / math.max(running, 1)))
	add(string.format("  garbage collections seen: %d (%.0f MB freed), %d of them during a stutter",
		gcRuns, gcFreedKB / 1024, gcInHitches))
	add("  A collection starts in whatever code needs memory at that moment, so its time")
	add("  shows up there. The addons that make the most memory make collections come sooner:")
	local garbage, sum = {}, 0
	for addon, kb in pairs(made) do
		sum = sum + kb
		if kb > 0 then table.insert(garbage, { addon = addon, kb = kb }) end
	end
	table.sort(garbage, function(x, y) return x.kb > y.kb end)
	if table.getn(garbage) == 0 then add("  none yet") end
	for i = 1, math.min(10, table.getn(garbage)) do
		local g = garbage[i]
		add(string.format("%7.1f KB/s  %s", g.kb / math.max(running, 1), g.addon))
	end
	if grownKB > 0 and sum > 0 then
		add(string.format("  These handlers made %d%% of the new memory; the rest came from XML scripts,",
			math.min(100, math.floor(sum / grownKB * 100 + 0.5))))
		add("  hooked functions and the game's own Lua.")
	end

	add("")
	add("SLOWEST HANDLERS (one call over " .. SLOW_MS .. " ms)")
	local slow = {}
	for _, s in pairs(db.slow) do table.insert(slow, s) end
	table.sort(slow, function(x, y) return x.worst > y.worst end)
	if table.getn(slow) == 0 then add("  none yet") end
	for i = 1, math.min(25, table.getn(slow)) do
		local s = slow[i]
		add(string.format("%6.1f ms worst, x%d  %s  %s %s%s%s", s.worst, s.count, s.addon, s.label, s.script,
			s.event and (" (" .. s.event .. ")") or "", s.gc and ", worst one held a garbage collection" or ""))
	end

	add("")
	add("CPU PER ADDON since /reload (" .. Duration(running) .. ")")
	local list = {}
	for addon, t in pairs(totals) do table.insert(list, { addon = addon, ms = t }) end
	table.sort(list, function(x, y) return x.ms > y.ms end)
	for i = 1, table.getn(list) do
		local e = list[i]
		add(string.format("%7.2f ms/s  %s", e.ms / math.max(running, 1), e.addon))
	end
	return "Stutter profiler", table.getn(db.hitches) .. " stutters saved. Covers scripts set from Lua, not XML.",
		table.concat(lines, "\n")
end

local function Clear()
	db.hitches, db.slow, db.slowCount = {}, {}, 0
	peakKB, grownKB, gcRuns, gcFreedKB, gcInHitches = lastKB or 0, 0, 0, 0, 0
	table.wipe(totals)
	table.wipe(made)
	startedAt = GetTime()
end

table.insert(EL.onLoad, function(saved)
	db = saved
	db.hitches = db.hitches or {}
	db.slow = db.slow or {}
	db.slowCount = db.slowCount or 0
	if not db.profile then return end
	active = true
	HookWidgets()
	HookTimers()
	startedAt = GetTime()
	driver:SetScript("OnUpdate", Tick)
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:SetScript("OnEvent", function() quietUntil = GetTime() + 5 end)
	EL.Print("stutter profiler on: /lag to view, /lag off to stop.")
end)

function EL.OpenStutters() EL.ShowReport(Report, Clear) end

SLASH_ERRORLOGLAG1 = "/lag"
SlashCmdList["ERRORLOGLAG"] = function(arg)
	arg = string.lower(arg or "")
	if not db then return end
	if arg == "on" or arg == "off" then
		local want = arg == "on"
		if want == (active and true or false) then
			EL.Print("stutter profiler is already " .. arg .. ".")
			return
		end
		-- Hooks go in at load, so switching takes a UI reload.
		db.profile = want
		ReloadUI()
	elseif arg == "clear" then
		Clear()
		EL.Print("stutter data cleared.")
		if ErrorLogWindow and ErrorLogWindow:IsShown() then EL.OpenStutters() end
	else
		EL.OpenStutters()
	end
end

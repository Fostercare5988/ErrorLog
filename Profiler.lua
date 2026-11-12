-- Stutter finder. While on (/lag on) every OnEvent,
-- OnUpdate, OnShow and OnHide script an addon sets, every C_Timer callback and
-- every hooksecurefunc hook is timed and its new Lua memory counted, for the
-- addon that set it. After login the scripts written in XML (the game's own
-- frames and addon XML files) are timed too, as "Game UI and XML". Each call is
-- charged only its own time: a hook inside a game handler goes to the hook's
-- addon, not to the handler.
-- A frame that takes longer than HITCH_MS is saved with the addons that ran
-- during it and the events that fired in it, so you can see whether a stutter
-- was addon code or the game itself, and what set it off.
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
local UI = "Game UI and XML" -- where XML scripts and the game's own handlers are charged

local db
local active
local startedAt, quietUntil = 0, 0
local lastHitchAt = 0 -- GetTime() of the last slow frame this session
-- What the XML pass at login did: frames walked, of a known widget type, scripts wrapped.
local xml = { frames = 0, known = 0, scripts = 0 }

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
-- Time and memory of the calls nested inside the call at each depth, so a
-- parent is charged only its own part.
local childMs, childKB = {}, {}
-- Time since the last driver tick, per addon; reused to avoid garbage.
local used, calls, worst, worstLabel = {}, {}, {}, {}
local totals = {} -- addon -> ms this session
-- New Lua memory made inside each addon's handlers (KB this session). The
-- counter only grows between collections, so the rise across a call is what
-- it made; a fall means a collection ran inside that call (gcIn).
local made = {}
local gcIn
local origOf = setmetatable({}, { __mode = "k" }) -- wrapper -> original

-- The longest stretch of the frame in which no timed script ran: the engine or
-- a DLL at work. What ran just before and after it (a script, an event by its
-- name, or the profiler's own tick) places it inside the frame.
local TICK = "frame tick"
local gapMs, gapFrom, gapTo = 0, nil, nil
local lastEnd, lastWhat = clock(), TICK
-- The same between events only: which event the engine was working towards.
local evGapMs, evFrom, evTo = 0, nil, nil
local lastEv, lastEvName = clock(), TICK
local function Step(what) return what and (string.find(what, " ") and what or ("event " .. what)) end

-- The addon folder and file of a stack path. The game keeps only the last 52
-- characters of a long path ("...dOns\Folder\file.lua", or the folder cut too:
-- "...ScrollingBattleText\file.lua"); a cut folder is the one installed
-- addon whose name ends that way.
local folders
local function FolderOf(path)
	local _, _, folder, file = string.find(path, "AddOns\\([^\\]+)\\(.+)$")
	if folder then return folder, file end
	local _, _, head, rest = string.find(path, "^%.%.%.([^\\]*)\\(.+)$")
	if not head or head == "" then return end
	if string.sub("AddOns", -#head) == head then
		return string.match(rest, "^([^\\]+)\\(.+)$")
	end
	if #head < 3 then return end
	if not folders then
		folders = {}
		for i = 1, GetNumAddOns() do folders[i] = (GetAddOnInfo(i)) end
	end
	for i = 1, #folders do
		local name = folders[i]
		if string.sub(name, -#head) == head then
			if folder then return end -- two addons end that way: unknown
			folder = name
		end
	end
	if folder then return folder, rest end
end

-- "Lifecycle.lua:60" and the addon folder, from the code that set the script.
-- A shared helper (HookScript and the like) is shown with its caller.
local function Origin()
	local stack = debugstack(2, 6, 0) or ""
	local addon, label
	for path, line in string.gmatch(stack, "([^\n<>]-%.lua):(%d+)") do
		local folder, file = FolderOf(path)
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

-- One finished call at depth d: its own time and memory (its total minus the
-- nested calls already charged) go to its addon, its total to its parent.
local function Charge(addon, label, script, d, ms, kb, a, b)
	local own, ownKB = ms - childMs[d], kb - childKB[d]
	if d > 1 then
		childMs[d - 1] = childMs[d - 1] + ms
		childKB[d - 1] = childKB[d - 1] + kb
	end
	used[addon] = (used[addon] or 0) + own
	calls[addon] = (calls[addon] or 0) + 1
	if own > (worst[addon] or 0) then
		worst[addon] = own
		worstLabel[addon] = label .. " " .. script
	end
	-- A fall means a collection ran inside; the innermost call keeps the blame.
	if kb >= 0 then made[addon] = (made[addon] or 0) + math.max(ownKB, 0) else gcIn = gcIn or addon end
	if own >= SLOW_MS then NoteSlow(addon, label, script, own, script == "OnEvent" and EventName(a, b) or nil, kb < 0 or nil) end
end

local function Wrap(fn, script)
	if type(fn) ~= "function" or origOf[fn] then return fn end
	local addon, label = Origin()
	if not addon then return fn end -- the game's own handlers: WrapXMLScripts
	local what = addon .. " " .. label .. " " .. script
	local wrapper = function(...)
		depth = depth + 1
		local d = depth
		childMs[d], childKB[d] = 0, 0
		local kb = LuaKB()
		local start = clock()
		if d == 1 and start - lastEnd > gapMs then gapMs, gapFrom, gapTo = start - lastEnd, lastWhat, what end
		fn(...)
		local stop = clock()
		local ms = stop - start
		if d == 1 then lastEnd, lastWhat = stop, what end
		kb = LuaKB() - kb
		depth = d - 1
		Charge(addon, label, script, d, ms, kb, ...)
	end
	origOf[wrapper] = fn
	return wrapper
end

-- XML scripts read this, event and arg1... as globals; a fixed set of
-- arguments passes on whatever the engine gives without a table per call.
local function WrapXML(fn, script, label)
	local what = label .. " " .. script
	local wrapper = function(a1, a2, a3, a4, a5, a6, a7, a8, a9)
		depth = depth + 1
		local d = depth
		childMs[d], childKB[d] = 0, 0
		local kb = LuaKB()
		local start = clock()
		if d == 1 and start - lastEnd > gapMs then gapMs, gapFrom, gapTo = start - lastEnd, lastWhat, what end
		fn(a1, a2, a3, a4, a5, a6, a7, a8, a9)
		local stop = clock()
		local ms = stop - start
		if d == 1 then lastEnd, lastWhat = stop, what end
		kb = LuaKB() - kb
		depth = d - 1
		Charge(UI, label, script, d, ms, kb, a1, a2)
	end
	origOf[wrapper] = fn
	return wrapper
end

-- The real SetScript and GetScript of each widget type, for WrapXMLScripts.
local rawSet, rawGet = {}, {}

local function HookWidgets()
	local done = {}
	for _, kind in ipairs({ "Frame", "Button", "CheckButton", "StatusBar", "Slider", "EditBox", "ScrollFrame",
		"ScrollingMessageFrame", "MessageFrame", "Model", "PlayerModel", "ColorSelect", "GameTooltip", "Cooldown" }) do
		local sample = CreateFrame(kind)
		-- A new EditBox auto-focuses and would swallow every key press, so
		-- every sample is hidden and the edit box let go of the keyboard.
		if sample.SetAutoFocus then sample:SetAutoFocus(false) end
		if sample.ClearFocus then sample:ClearFocus() end
		if sample.EnableKeyboard then sample:EnableKeyboard(false) end
		sample:Hide()
		local mt = getmetatable(sample)
		local index = mt and type(mt.__index) == "table" and mt.__index
		if index and not done[index] and index.SetScript then
			done[index] = true
			local set, get = index.SetScript, index.GetScript
			rawSet[index], rawGet[index] = set, get
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

-- An addon's hooksecurefunc hook runs inside the game function it follows,
-- where no script wrapper sees it.
local function HookHooks()
	local real = hooksecurefunc
	if not real then return end
	hooksecurefunc = function(a, b, c)
		if type(a) == "string" then return real(a, Wrap(b, "hook " .. a)) end
		return real(a, b, Wrap(c, "hook " .. tostring(b)))
	end
end

-- Runs once per frame: the gap since the last tick is the frame time, and
-- everything charged since then ran during that frame.
local driver = CreateFrame("Frame")

-- Every event, counted per frame, so a stutter shows what happened in it (a
-- pack dying, nameplates leaving) even when the time went to the game itself.
local counter = CreateFrame("Frame")
local evCount, evSeen = {}, false
local function CountEvent(_, ev)
	ev = type(ev) == "string" and ev or event
	evCount[ev] = (evCount[ev] or 0) + 1
	evSeen = true
	-- An event the engine sends by itself (not from inside a script) is a step
	-- of the frame too.
	if depth == 0 then
		local t = clock()
		if t - lastEnd > gapMs then gapMs, gapFrom, gapTo = t - lastEnd, lastWhat, ev end
		lastEnd, lastWhat = t, ev
		if t - lastEv > evGapMs then evGapMs, evFrom, evTo = t - lastEv, lastEvName, ev end
		lastEv, lastEvName = t, ev
	end
end
local function TopEvents()
	if not evSeen then return nil end
	local list = {}
	for ev, n in pairs(evCount) do table.insert(list, { ev = ev, n = n }) end
	table.sort(list, function(x, y) return x.n > y.n end)
	local out = {}
	for i = 1, math.min(12, #list) do out[i] = list[i].ev .. " x" .. list[i].n end
	return table.concat(out, ", ")
end

-- The frame time is the clock between two ticks: the same window the handler
-- times are charged in. The engine's elapsed is measured from its own point in
-- the frame, so a slow event handler could be charged to the frame before the
-- one that looked slow, leaving the stutter with no addon time.
local lastClock
local function Tick()
	local now = GetTime()
	local tick = clock()
	local ms = lastClock and tick - lastClock or 0
	lastClock = tick
	if tick - lastEnd > gapMs then gapMs, gapFrom, gapTo = tick - lastEnd, lastWhat, TICK end
	if tick - lastEv > evGapMs then evGapMs, evFrom, evTo = tick - lastEv, lastEvName, TICK end
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
			if ms > h.ms then
				h.ms, h.lua, h.top, h.events = ms, lua, table.concat(top, "; "), TopEvents()
				h.gap, h.gapFrom, h.gapTo = gapMs, Step(gapFrom), Step(gapTo)
				h.evGap, h.evFrom, h.evTo = evGapMs, Step(evFrom), Step(evTo)
			end
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
				events = TopEvents(),
				gc = freed > 0 and freed / 1024 or nil,
				gcIn = freed > 0 and gcIn or nil,
				heap = kb / 1024,
				gap = gapMs,
				gapFrom = Step(gapFrom),
				gapTo = Step(gapTo),
				evGap = evGapMs,
				evFrom = Step(evFrom),
				evTo = Step(evTo),
			})
			while table.getn(db.hitches) > MAX_HITCHES do table.remove(db.hitches) end
		end
		lastHitchAt = now
		if freed > 0 then gcInHitches = gcInHitches + 1 end
	end
	for addon in pairs(used) do used[addon], calls[addon], worst[addon] = 0, 0, 0 end
	gcIn = nil
	depth = 0 -- a handler that errored never got to decrement it
	if evSeen then table.wipe(evCount); evSeen = false end
	gapMs, gapFrom, gapTo = 0, nil, nil
	evGapMs, evFrom, evTo = 0, nil, nil
	lastEnd, lastWhat = clock(), TICK
	lastEv, lastEvName = lastEnd, TICK
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
		if h.events then add("    events: " .. h.events) end
		if h.gapFrom then
			add(string.format("    longest pause with no script running: %d ms, after %s, before %s", h.gap, h.gapFrom, h.gapTo))
		end
		if h.evFrom then
			add(string.format("    longest pause between events: %d ms, after %s, before %s", h.evGap, h.evFrom, h.evTo))
		end
	end
	add("Addon time covers addon scripts, timers and hooks, and the game's own UI scripts")
	add('("Game UI and XML"). The rest of a stutter went to the game engine and its DLLs')
	add("(drawing, loading models, nameplates), Lua garbage collection or the server; the")
	add("events line shows what happened in that frame. A long run of slow frames with")
	add("almost no addon time is usually the game alt-tabbed or the GPU.")
	add("The longest pause is where the engine spent its time: between two events it was")
	add("handling what the server sent; next to the frame tick it was updating or drawing")
	add("the world.")

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
		add(string.format("  These handlers made %d%% of the new memory; the rest came from code outside",
			math.min(100, math.floor(sum / grownKB * 100 + 0.5))))
		add("  any timed call: replaced game functions, slash commands, and scripts of frames")
		add("  built from XML templates after login.")
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
	return "Stutter profiler", table.getn(db.hitches) .. " stutters saved. Covers addon scripts, timers, hooks and "
		.. xml.scripts .. " XML scripts" .. (xml.error and " (the XML pass failed: " .. xml.error .. ")" or "") .. ".",
		table.concat(lines, "\n")
end

local function Clear()
	db.hitches, db.slow, db.slowCount = {}, {}, 0
	peakKB, grownKB, gcRuns, gcFreedKB, gcInHitches = lastKB or 0, 0, 0, 0, 0
	table.wipe(totals)
	table.wipe(made)
	startedAt = GetTime()
end

-- Scripts written in XML, and those the game's own Lua sets, never pass through
-- an addon's SetScript call. Once everything has loaded they are wrapped in
-- place, under the frame's name. Frames built from XML templates later stay
-- unwrapped.
local function WrapXMLScripts()
	local f = EnumerateFrames()
	while f do
		local mt = getmetatable(f)
		local index = mt and mt.__index
		local get = index and rawGet[index]
		xml.frames = xml.frames + 1
		if get and f ~= driver and f ~= counter then
			xml.known = xml.known + 1
			local name
			for script in pairs(WRAPPED) do
				local fn = get(f, script)
				if type(fn) == "function" and not origOf[fn] then
					name = name or f:GetName() or "unnamed frame"
					rawSet[index](f, script, WrapXML(fn, script, name))
					xml.scripts = xml.scripts + 1
				end
			end
		end
		f = EnumerateFrames(f)
	end
end

-- Saved at logout and reload, so the numbers of the report can be read from
-- the saved file: per addon ms and new KB per second, and what the XML pass did.
local function Snapshot()
	local running = math.max(GetTime() - startedAt, 1)
	db.seconds, db.cpu, db.garbage = running, {}, {}
	for addon, t in pairs(totals) do db.cpu[addon] = t / running end
	for addon, kb in pairs(made) do db.garbage[addon] = kb / running end
	db.xml = xml
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
	HookHooks()
	startedAt = GetTime()
	driver:SetScript("OnUpdate", Tick)
	driver:RegisterEvent("PLAYER_LOGIN")
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:RegisterEvent("PLAYER_LOGOUT")
	driver:SetScript("OnEvent", function()
		if event == "PLAYER_LOGOUT" then Snapshot() return end
		if event == "PLAYER_LOGIN" then
			local ok, err = pcall(WrapXMLScripts)
			xml.error = not ok and tostring(err) or nil
		end
		quietUntil = GetTime() + 5
	end)
	counter:SetScript("OnEvent", CountEvent)
	counter:RegisterAllEvents()
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

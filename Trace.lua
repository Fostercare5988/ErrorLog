-- Trace: finds where the game freezes. A freeze loses everything kept in
-- memory, so each step of the traced addon is written to disk the moment it
-- happens (NamPower's WriteCustomFile); the last line is where it stopped.
--   /trace <name> [name...]  record every function whose name starts with a
--                            name (Bagnon, Banknon), the game calls made inside
--                            them, and the event that led there
--   /trace off               stop and take the hooks out
--   /trace                   is it recording?
-- It stays on across /reload and login until /trace off. The two files in
-- CustomData take turns, MAX_LINES each, so the newest lines are always kept.
local EL = ErrorLog
if not EL then return end
local Print = EL.Print

local FILES = { "ErrorLogTraceA.txt", "ErrorLogTraceB.txt" }
local MAX_LINES = 20000

-- Taken before any hook goes in: the recorder must not record itself.
local write, clock, today = WriteCustomFile, GetTime, date
local format, rep, sub, gsub, lower, find = string.format, string.rep, string.sub, string.gsub, string.lower, string.find
local type, tostring, select, pcall, pairs, rawget = type, tostring, select, pcall, pairs, rawget

-- Never hooked: Lua's own functions and those that count stack levels.
local SKIP = {}
for name in string.gmatch("getfenv setfenv error pcall xpcall loadstring assert select unpack type tostring tonumber next pairs ipairs "
	.. "rawget rawset rawequal setmetatable getmetatable gcinfo collectgarbage debugstack debuglocals debugprofilestop "
	.. "GetCallstackHeight GetErrorCallstackHeight geterrorhandler seterrorhandler hooksecurefunc WriteCustomFile GetTime date time", "%S+") do
	SKIP[name] = true
end
-- The game's global names for the string, math and table functions (strfind, floor, tinsert).
local LIBRARY = {}
for _, lib in pairs({ string, math, table }) do
	for _, fn in pairs(lib) do LIBRARY[fn] = true end
end

local db
local on, depth, lines, part = false, 0, 0, 0
local names, title          -- lower-case name starts; what the player typed
local hooks = {}            -- { owner, key, original, hook }
local frame
local lastEvent, lastArg1, lastArg2

local function NextFile()
	part = part + 1
	lines = 0
	pcall(write, FILES[(part - 1) % 2 + 1],
		format("!ErrorLog trace of %s, part %d, %s (the other file holds the part before)\n", title, part, today("%Y-%m-%d %H:%M:%S")), "w")
end

local function Line(text)
	if lines >= MAX_LINES then NextFile() end
	lines = lines + 1
	pcall(write, FILES[(part - 1) % 2 + 1], format("%05d %.3f %s%s\n", lines, clock(), rep("  ", depth), text), "a")
end

local function Value(v)
	local kind = type(v)
	if kind == "string" then
		return '"' .. gsub(sub(v, 1, 60), "[\r\n]", " ") .. '"'
	elseif kind == "table" then
		local getName = v.GetName
		if type(getName) == "function" then
			local ok, name = pcall(getName, v)
			if ok and type(name) == "string" then return "<" .. name .. ">" end
		end
		return "table"
	elseif kind == "function" or kind == "userdata" then
		return kind
	end
	return tostring(v)
end

local function Values(...)
	local n = select("#", ...)
	if n == 0 then return "" end
	local text = Value((...))
	for i = 2, n > 6 and 6 or n do text = text .. ", " .. Value((select(i, ...))) end
	return text
end

local function Leave(label, ...)
	if depth > 0 then depth = depth - 1 end
	Line("<" .. label .. " = " .. Values(...))
	return ...
end

local function Enter(label, ...)
	-- The event that led to the first step of this frame, once.
	if depth == 0 and lastEvent then
		Line("EVENT " .. lastEvent .. " " .. Value(lastArg1) .. " " .. Value(lastArg2))
		lastEvent = nil
	end
	Line(">" .. label .. "(" .. Values(...) .. ")")
	depth = depth + 1
end

-- A function of the traced addon: always recorded.
local function AddonCall(label, original)
	return function(...)
		if not on then return original(...) end
		Enter(label, ...)
		return Leave(label, original(...))
	end
end

-- Any other global or C_ function: recorded only inside the traced addon.
local function GameCall(label, original)
	return function(...)
		if depth == 0 or not on then return original(...) end
		Enter(label, ...)
		return Leave(label, original(...))
	end
end

local function Hook(owner, key, original, make, label)
	local hook = make(label, original)
	owner[key] = hook
	hooks[#hooks + 1] = { owner, key, original, hook }
end

local function Traced(name)
	name = lower(name)
	for i = 1, #names do
		if find(name, names[i], 1, true) == 1 then return true end
	end
end

local function HookFields(owner, prefix, make)
	local n = 0
	for key, value in pairs(owner) do
		if type(key) == "string" and type(value) == "function" then
			Hook(owner, key, value, make, prefix .. "." .. key)
			n = n + 1
		end
	end
	return n
end

local function Stop()
	on, depth = false, 0
	for i = 1, #hooks do
		local h = hooks[i]
		-- Someone hooked over ours since: leave theirs, ours passes straight through.
		if rawget(h[1], h[2]) == h[4] then h[1][h[2]] = h[3] end
	end
	hooks = {}
	if frame then
		frame:UnregisterAllEvents()
		frame:SetScript("OnUpdate", nil)
	end
end

local function Start(text)
	if type(write) ~= "function" then Print("/trace needs NamPower (WriteCustomFile).") return end
	Stop()
	names, title = {}, text
	for name in string.gmatch(text, "%S+") do names[#names + 1] = lower(name) end

	local found = 0
	for key, value in pairs(_G) do
		if type(key) == "string" then
			if type(value) == "function" then
				if not SKIP[key] and not LIBRARY[value] then
					local traced = Traced(key)
					if traced then found = found + 1 end
					Hook(_G, key, value, traced and AddonCall or GameCall, key)
				end
			-- Tables of functions; not frames (they hold a userdata at 0).
			elseif type(value) == "table" and value ~= _G and value ~= EL and type(rawget(value, 0)) ~= "userdata" then
				if Traced(key) then
					found = found + HookFields(value, key, AddonCall)
				elseif sub(key, 1, 2) == "C_" and key ~= "C_Timer" then
					HookFields(value, key, GameCall)
				end
			end
		end
	end
	if found == 0 then
		Stop()
		db.trace = nil
		Print("no function starts with " .. text .. ". Use the addon's name, like /trace Bagnon Banknon.")
		return
	end

	if not frame then
		frame = CreateFrame("Frame")
		frame:SetScript("OnEvent", function() lastEvent, lastArg1, lastArg2 = event, arg1, arg2 end)
	end
	frame:RegisterAllEvents()
	-- An error inside a traced function skips its Leave; start each frame level.
	frame:SetScript("OnUpdate", function() depth = 0 end)

	db.trace = text
	on, depth, part, lastEvent = true, 0, part, nil
	NextFile()
	Print(("recording %s (%d functions) into CustomData\\%s. /trace off stops it."):format(text, found, FILES[(part - 1) % 2 + 1]))
end

EL.onLoad[#EL.onLoad + 1] = function(saved) db = saved end

-- Still on from before: start again once every addon has loaded its functions.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	if db and type(db.trace) == "string" then Start(db.trace) end
end)

SLASH_ERRORLOGTRACE1 = "/trace"
SlashCmdList["ERRORLOGTRACE"] = function(msg)
	if not db then return end
	msg = string.match(msg or "", "^%s*(.-)%s*$")
	if lower(msg) == "off" then
		Stop()
		db.trace = nil
		Print("trace off.")
	elseif msg ~= "" then
		Start(msg)
	elseif on then
		Print(("recording %s into CustomData\\%s and %s. /trace off stops it."):format(title, FILES[1], FILES[2]))
	else
		Print("trace is off. /trace <addon name> records that addon's steps to a file, to find a freeze.")
	end
end

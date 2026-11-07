-- Game checks: what an audit could not prove outside the game. VanillaForge's
-- tools/game_checks.py puts the open ones in ErrorLog_DB.checks while the game
-- is closed and reads the answers back the next time it runs.
--   /check             the next open check
--   /check ok [note]   it works as described
--   /check bad <note>  it does not: say what you saw
--   /check run         run the check's /run line and keep what it printed
--   /check skip        the one after
--   /check list        how many are open, per addon
local EL = ErrorLog
if not EL then return end
local Print = EL.Print

local checks -- { id, addon, where, text, run, and once answered: verdict, note, at, who, output }
local current = 0

local function IsOpen(c) return c and not c.verdict end

local function OpenCount()
	local n = 0
	for i = 1, #checks do if IsOpen(checks[i]) then n = n + 1 end end
	return n
end

-- The next open check after `from`, wrapping round; 0 when none is open.
local function NextOpen(from)
	local n = #checks
	for step = 1, n do
		local i = (from + step - 1) % n + 1
		if IsOpen(checks[i]) then return i end
	end
	return 0
end

local function Show()
	if not IsOpen(checks[current]) then current = NextOpen(current) end
	local c = checks[current]
	if not c then Print("no game checks are open.") return end
	Print(("%d open. |cffffd100%s|r: %s |cff808080(%s)|r"):format(OpenCount(), c.addon, c.text, c.where))
	if c.run then Print("/check run tries: " .. c.run) end
	Print("Answer with /check ok, /check bad <what you saw>, or /check skip.")
end

local function Answer(verdict, note)
	local c = checks[current]
	if not IsOpen(c) then Show() return end
	if verdict == "bad" and note == "" then Print("say what you saw: /check bad <what you saw>") return end
	c.verdict, c.at, c.who = verdict, date("%Y-%m-%d %H:%M"), UnitName("player")
	if note ~= "" then c.note = note end
	Print("recorded " .. verdict .. ".")
	current = NextOpen(current)
	Show()
end

-- Runs the check's /run line once and keeps what it printed with the answer.
local function Run()
	local c = checks[current]
	if not IsOpen(c) or not c.run then Print("this check has no /run line.") return end
	local out, quiet = {}, false
	local frame = DEFAULT_CHAT_FRAME
	local add, printer = frame.AddMessage, print
	frame.AddMessage = function(self, msg, r, g, b, id)
		if not quiet then out[#out + 1] = tostring(msg) end
		return add(self, msg, r, g, b, id)
	end
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		out[#out + 1] = table.concat(parts, " ")
		quiet = true
		printer(...)
		quiet = false
	end
	local fn, err = loadstring((string.gsub(c.run, "^/%a+%s+", "")))
	local ok, runErr = true, nil
	if fn then ok, runErr = pcall(fn) end
	frame.AddMessage, print = add, printer
	if not fn or not ok then
		out[#out + 1] = "error: " .. tostring(err or runErr)
		Print(out[#out])
	end
	c.output = string.sub(table.concat(out, " | "), 1, 500)
	Print("kept what it printed. Now /check ok or /check bad <what you saw>.")
end

local function List()
	local open, order = {}, {}
	for i = 1, #checks do
		local c = checks[i]
		if IsOpen(c) then
			if not open[c.addon] then open[c.addon] = 0; order[#order + 1] = c.addon end
			open[c.addon] = open[c.addon] + 1
		end
	end
	if #order == 0 then Print("no game checks are open.") return end
	table.sort(order)
	for i = 1, #order do Print(("%s: %d open"):format(order[i], open[order[i]])) end
end

EL.onLoad[#EL.onLoad + 1] = function(db) checks = db.checks end

-- One line at login while checks are open.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_ENTERING_WORLD")
login:SetScript("OnEvent", function()
	login:UnregisterEvent("PLAYER_ENTERING_WORLD")
	local n = checks and OpenCount() or 0
	if n > 0 then Print(("%d game checks are open: type /check."):format(n)) end
end)

SLASH_ERRORLOGCHECK1 = "/check"
SlashCmdList["ERRORLOGCHECK"] = function(msg)
	if not checks or #checks == 0 then Print("no game checks yet.") return end
	local cmd, rest = string.match(msg or "", "^(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "ok" or cmd == "bad" then Answer(cmd, rest)
	elseif cmd == "run" then Run()
	elseif cmd == "skip" then current = NextOpen(current); Show()
	elseif cmd == "list" then List()
	else Show() end
end

-- !ErrorLog: catches every Lua error from any addon, keeps it across
-- sessions in SavedVariables (with stack, zone and counts) and shows it in a
-- window you can copy from, instead of the modal popup.
--   /err          open the window (the button in it switches to stutters)
--   /err clear    forget every saved error
--   /err popup    toggle Blizzard's error popup as well (off by default)
--   /err test     raise a test error
-- The stutter profiler's /lag commands are in Profiler.lua.
local MAX_ERRORS = 100

-- Shared with Profiler.lua.
ErrorLog = { onLoad = {} }

local pending = {} -- errors raised before SavedVariables load
local previous = (geterrorhandler and geterrorhandler()) or _ERRORMESSAGE
local db
local session = 0
local Window, Button -- built on demand / at load

local function Print(text)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffff4040ErrorLog:|r " .. text) end
end
ErrorLog.Print = Print

local function Now()
	return date("%Y-%m-%d %H:%M:%S")
end

-- The addon folder the error points at, from the message or else the stack.
local function AddonOf(msg, stack)
	local _, _, name = string.find(msg, "AddOns\\([^\\]+)\\")
	if not name and stack then _, _, name = string.find(stack, "AddOns\\([^\\]+)\\") end
	return name or "?"
end

local function Unseen()
	local n = 0
	if not db then return n end
	for i = 1, table.getn(db.errors) do
		if not db.errors[i].seen then n = n + 1 end
	end
	return n
end

local function UpdateButton()
	if not Button then return end
	local n = Unseen()
	if n > 0 then
		Button.Text:SetText(n)
		Button:Show()
	else
		Button:Hide()
	end
end

-- msg -> entry, so a repeat costs one lookup. Rebuilt whenever the list changes.
local byMsg = {}
local function Reindex()
	byMsg = {}
	if not db then return end
	for i = 1, table.getn(db.errors) do byMsg[db.errors[i].msg] = db.errors[i] end
end

local function ClearAll()
	db.errors = {}
	byMsg = {}
	UpdateButton()
end

-- Newest first; only needed when the window is about to show the list.
local function SortErrors()
	table.sort(db.errors, function(a, b) return a.last > b.last end)
end

-- An addon erroring every frame calls this every frame, so a repeat only bumps
-- the entry: no stack trace, no reorder, no redraw.
local function Record(msg, stack)
	if not db then
		if table.getn(pending) < 50 then table.insert(pending, { msg = msg, stack = stack }) end
		return
	end
	local e = byMsg[msg]
	if e then
		e.count = e.count + 1
		e.last = Now()
		e.lastSession = session
		if e.seen then
			e.seen = nil
			Print("again in " .. e.addon .. " (x" .. e.count .. ") - /err")
			UpdateButton()
		end
		return
	end
	local addon = AddonOf(msg, stack)
	e = {
		msg = msg,
		stack = stack or "",
		addon = addon,
		count = 1,
		first = Now(),
		last = Now(),
		zone = (GetRealZoneText and GetRealZoneText()) or "?",
		session = session,
		lastSession = session,
	}
	table.insert(db.errors, 1, e)
	byMsg[msg] = e
	if table.getn(db.errors) > MAX_ERRORS then
		SortErrors()
		while table.getn(db.errors) > MAX_ERRORS do table.remove(db.errors) end
		Reindex()
	end
	Print("new error in " .. addon .. " - /err")
	UpdateButton()
	if Window and Window:IsShown() then Window:Refresh() end
end

seterrorhandler(function(msg)
	msg = tostring(msg)
	-- The stack is only worth its cost the first time a message is seen.
	local stack
	if not byMsg[msg] and debugstack then stack = debugstack(2, 14, 0) end
	-- Never let the logger itself raise: that would recurse into this handler.
	pcall(Record, msg, stack)
	if previous and (not db or db.popup) then return previous(msg) end
end)

-- -------------------------------------------------------------------------- --
-- Window                                                                     --
-- -------------------------------------------------------------------------- --
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function Details(e)
	local lines = {
		"|cffff6060" .. e.msg .. "|r",
		"",
		"Addon:    " .. e.addon,
		"Seen:     " .. e.count .. "x, first " .. e.first .. ", last " .. e.last,
		"Zone:     " .. (e.zone or "?"),
		"Session:  " .. (e.session or "?") .. (e.lastSession ~= e.session and (" to " .. (e.lastSession or "?")) or "")
			.. (e.lastSession == session and "  (this session)" or ""),
		"",
		"Stack:",
		e.stack ~= "" and e.stack or "(none)",
	}
	return table.concat(lines, "\n")
end

-- Same text without colour codes, so a copy pastes cleanly.
local function Plain(text)
	text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
	text = string.gsub(text, "|r", "")
	return text
end

local function MakeButton(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetWidth(width)
	b:SetHeight(22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

local function BuildWindow()
	local w = CreateFrame("Frame", "ErrorLogWindow", UIParent)
	w:SetWidth(620)
	w:SetHeight(420)
	w:SetPoint("CENTER", 0, 40)
	w:SetFrameStrata("DIALOG")
	w:SetBackdrop(BACKDROP)
	w:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
	w:SetBackdropBorderColor(0.55, 0.55, 0.60, 1)
	w:EnableMouse(true)
	w:SetMovable(true)
	w:SetClampedToScreen(true)
	w:RegisterForDrag("LeftButton")
	w:SetScript("OnDragStart", function() this:StartMoving() end)
	w:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	w:Hide()
	tinsert(UISpecialFrames, "ErrorLogWindow") -- Escape closes it
	w.index = 1

	local title = w:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	w.Title = title

	local sub = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	sub:SetTextColor(0.7, 0.7, 0.7)
	w.Sub = sub

	local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)

	-- Switches between the error list and the stutter report.
	w.Switch = MakeButton(w, "Stutters", 80, function()
		if w.mode == "report" then ErrorLog.OpenErrors()
		elseif ErrorLog.OpenStutters then ErrorLog.OpenStutters() end
	end)
	w.Switch:SetPoint("TOPRIGHT", -34, -10)

	local box = CreateFrame("Frame", nil, w)
	box:SetPoint("TOPLEFT", 10, -52)
	box:SetPoint("BOTTOMRIGHT", -10, 40)
	box:SetBackdrop(BACKDROP)
	box:SetBackdropColor(0, 0, 0, 0.6)
	box:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)

	local scroll = CreateFrame("ScrollFrame", "ErrorLogScroll", box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(560)
	edit:SetHeight(300)
	edit:SetScript("OnEscapePressed", function() this:ClearFocus(); w:Hide() end)
	-- Read-only: any typing is put back, but selecting and Ctrl+C still work.
	edit:SetScript("OnTextChanged", function()
		if this.text and this:GetText() ~= this.text then this:SetText(this.text) end
		scroll:UpdateScrollChildRect()
	end)
	scroll:SetScrollChild(edit)
	w.Edit = edit

	local hint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 14, 16)
	hint:SetText("Select All, then Ctrl+C to copy")

	w.Prev = MakeButton(w, "< Newer", 80, function() w.index = w.index - 1; w:Refresh() end)
	w.Next = MakeButton(w, "Older >", 80, function() w.index = w.index + 1; w:Refresh() end)
	local selectAll = MakeButton(w, "Select All", 90, function()
		w.Edit:SetFocus()
		w.Edit:HighlightText()
	end)
	local clear = MakeButton(w, "Clear All", 80, function()
		if w.mode == "report" then
			if w.clearReport then w.clearReport() end
		else
			ClearAll()
			w.index = 1
		end
		w:Refresh()
	end)
	clear:SetPoint("BOTTOMRIGHT", -10, 10)
	w.Next:SetPoint("RIGHT", clear, "LEFT", -12, 0)
	w.Prev:SetPoint("RIGHT", w.Next, "LEFT", -4, 0)
	selectAll:SetPoint("RIGHT", w.Prev, "LEFT", -12, 0)

	local function SetBody(text)
		w.Edit.text = text
		w.Edit:SetText(text)
		w.Edit:HighlightText(0, 0)
		ErrorLogScroll:SetVerticalScroll(0)
	end

	function w:Refresh()
		self.Switch:SetText(self.mode == "report" and "Errors" or "Stutters")
		if ErrorLog.OpenStutters or self.mode == "report" then self.Switch:Show() else self.Switch:Hide() end
		if self.mode == "report" then
			local title, sub, text = self.report()
			self.Title:SetText(title)
			self.Sub:SetText(sub)
			SetBody(text)
			self.Prev:Disable()
			self.Next:Disable()
			return
		end
		local errors = db.errors
		local total = table.getn(errors)
		if self.index > total then self.index = total end
		if self.index < 1 then self.index = 1 end
		local text
		if total == 0 then
			self.Title:SetText("No errors")
			self.Sub:SetText("Nothing has gone wrong since the log was last cleared.")
			text = ""
		else
			local e = errors[self.index]
			e.seen = true
			local here = 0
			for i = 1, total do
				if errors[i].lastSession == session then here = here + 1 end
			end
			self.Title:SetText("Error " .. self.index .. " of " .. total .. "  |cffaaaaaa" .. e.addon .. "|r")
			self.Sub:SetText(here .. " seen this session, newest first. Popup: "
				.. (db.popup and "on" or "off") .. " (/err popup)")
			text = Plain(Details(e))
		end
		SetBody(text)
		if self.index > 1 then self.Prev:Enable() else self.Prev:Disable() end
		if self.index < total then self.Next:Enable() else self.Next:Disable() end
		UpdateButton()
	end
	return w
end

local function Open()
	if not db then return end
	if not Window then Window = BuildWindow() end
	SortErrors()
	Window.mode = "errors"
	Window.index = 1
	Window:Show()
	Window:Refresh()
end
ErrorLog.OpenErrors = Open

-- Show a text report in the same window. report() returns title, subtitle
-- and body; clear() runs on Clear All.
function ErrorLog.ShowReport(report, clear)
	if not db then return end
	if not Window then Window = BuildWindow() end
	Window.mode, Window.report, Window.clearReport = "report", report, clear
	Window:Show()
	Window:Refresh()
end

-- A small red counter that appears while there are unread errors; click it
-- to open the window, drag to move it.
local function BuildButton()
	local b = CreateFrame("Button", "ErrorLogButton", UIParent)
	b:SetWidth(28)
	b:SetHeight(28)
	b:SetFrameStrata("HIGH")
	b:SetBackdrop(BACKDROP)
	b:SetBackdropColor(0.55, 0.05, 0.05, 0.9)
	b:SetBackdropBorderColor(1, 0.3, 0.3, 1)
	b:SetMovable(true)
	b:SetClampedToScreen(true)
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", function() this:StartMoving() end)
	b:SetScript("OnDragStop", function()
		this:StopMovingOrSizing()
		local point, _, rel, x, y = this:GetPoint()
		db.button = { point = point, rel = rel, x = x, y = y }
	end)
	b:SetScript("OnClick", Open)
	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT")
		GameTooltip:AddLine("Lua errors")
		GameTooltip:AddLine(Unseen() .. " unread. Click to view, drag to move.", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	t:SetPoint("CENTER", 0, 0)
	b.Text = t
	local p = db.button
	if p then
		b:SetPoint(p.point, UIParent, p.rel, p.x, p.y)
	else
		b:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -10)
	end
	b:Hide()
	return b
end

-- Our own ADDON_LOADED comes before any later addon loads, so the profiler
-- can hook in before they create their frames.
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
	name = name or arg1
	if name ~= "!ErrorLog" then return end
	f:UnregisterEvent("ADDON_LOADED")
	-- The first version saved a plain list of errors; start fresh from it.
	if type(ErrorLog_DB) ~= "table" or type(ErrorLog_DB.errors) ~= "table" then
		ErrorLog_DB = { errors = {}, session = 0, popup = false }
	end
	db = ErrorLog_DB
	ErrorLog.db = db
	db.session = (db.session or 0) + 1
	session = db.session
	Reindex()
	Button = BuildButton()
	for i = 1, table.getn(pending) do Record(pending[i].msg, pending[i].stack) end
	pending = {}
	UpdateButton()
	for i = 1, table.getn(ErrorLog.onLoad) do ErrorLog.onLoad[i](db) end
end)

SLASH_ERRORLOG1 = "/err"
SLASH_ERRORLOG2 = "/errlog"
SLASH_ERRORLOG3 = "/errors"
SlashCmdList["ERRORLOG"] = function(arg)
	arg = string.lower(arg or "")
	if not db then return end
	if arg == "clear" then
		ClearAll()
		if Window and Window:IsShown() then Window:Refresh() end
		Print("cleared.")
	elseif arg == "popup" then
		db.popup = not db.popup
		Print("Blizzard error popup " .. (db.popup and "on" or "off") .. ".")
	elseif arg == "test" then
		error("ErrorLog test error")
	else
		Open()
	end
end

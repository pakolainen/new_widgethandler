--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    handler.lua
--  brief:   the widget manager, a call-in router
--  author:  jK (based heavily on code by Dave Rodgers)
--
--  Copyright (C) 2007,2008,2009,2010,2011.
--  Licensed under the terms of the GNU GPL, v2 or later.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--FIXME add require/depend to reload other widgets when one crashes
--FIXME name widgets & gadgets Extensions internally
--FIXME rev2 & handler:Remove()
--FIXME add AllowWidgetLoading event

require "setupdefs.lua"
require "savetable.lua"
require "keysym.lua"
require "actions.lua"

--// make a copy of the engine exported enviroment (we use this later for the widgets!)
local EG = {}
for i,v in pairs(_G) do
	EG[i] = v
end

--[[
do
	local i=0
	local function hook(event)
		i = i + 1
		if ((i % (10^7)) < 1) then
			i = 0
			Spring.Echo(Spring.GetGameFrame(), event, debug.getinfo(2).name)
			Spring.Echo(debug.traceback())
		end
	end

	debug.sethook(hook,"r",10^100)
end
--]]

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- SpeedUp & Helpers

local spEcho       = Spring.Echo
local glPopAttrib  = gl.PopAttrib
local glPushAttrib = gl.PushAttrib
local type   = type
local pcall  = pcall
local pairs  = pairs
local ipairs = ipairs
local emptyTable = {}

if (not VFS.GetFileChecksum) then
	function VFS.GetFileChecksum(file, _VFSMODE)
		local data = VFS.LoadFile(file, _VFSMODE)
		if (data) then
			local datalen     = data:len()/4
			local striplength = 1024*10 --10kB

			if (striplength >= datalen) then
				local bytes = VFS.UnpackU32(data,nil,datalen)
				local checksum = math.bit_xor(0,unpack(bytes))
				return checksum
			end

			--// stack is limited, so split up the data
			local start = 1
			local crcs = {}
			repeat
				local strip = data:sub(start,start+striplength)
				local bytes = VFS.UnpackU32(strip,nil,strip:len()/4)
				local checksum = math.bit_xor(0,unpack(bytes))
				crcs[#crcs+1] = checksum
				start = start + striplength
			until (start >= datalen)

			local checksum = math.bit_xor(0,unpack(crcs))
			return checksum
		end
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Table functions

local function CopyTable(t1, t2)
	--FIXME recursive?
	for i,v in pairs(t2) do
		t1[i] = v
	end
end

local function tappend(t1, t2)
	for i=1,#t2 do
		t1[#t1+1] = t2[i]
	end
end

local function tfind(t, item)
	if (not t)or(item == nil) then return false end
	for i=1,#t do
		if t[i] == item then
			return true
		end
	end
	return false
end

local function tprinttable(t, columns)
	local formatstr = "  " .. string.rep("%-25s, ", columns)
	for i=1, #t, columns do
		if (i+columns > #t) then
			formatstr = "  " .. string.rep("%-25s, ", #t - i - 1) .. "%-25s"
		end
		local s = formatstr:format(select(i,unpack(t)))
		spEcho("  " .. s)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- A Lua List Object

local function SortFuncExtension(ki1, ki2)
	if tfind(ki1.before, ki2.name) or tfind(ki2.after, ki1.name) then
		return true
	end
	if tfind(ki2.before, ki1.name) or tfind(ki1.after, ki2.name) then
		return false
	end
	
	if tfind(ki1.before, "all") then
		return true
	end
	if tfind(ki2.before, "all") then
		return false
	end

	if (ki1.api ~= ki2.api) then
		return (ki1.api)
	end

	local l1 = ki1.layer or math.huge
	local l2 = ki2.layer or math.huge
	if (l1 ~= l2) then
		return (l1 < l2)
	end

	local o1 = handler.orderList[n1] or math.huge
	local o2 = handler.orderList[n2] or math.huge
	if (o1 ~= o2) then
		return (o1 < o2)
	end

	if (ki1.fromZip ~= ki2.fromZip) then --// load zip files first, so they can prevent hacks/cheats ...
		return (ki1.fromZip)
	end

	return (ki1.name < ki2.name)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- A Lua List Object

local CreateList
do
	--// use array indices for most used entries (faster)
	local DATA  = 1
	local NEXT  = 2
	local PREV  = 3

	local function List_InsertNewListItem(self, owner, data, prev, next)
		local newItem = {
			owner  = owner; --// external code uses this too, so don't hide it behind a magic index
			[DATA]  = data;
			[NEXT]  = next;
			[PREV]  = prev
		}
		if (prev) then prev[NEXT] = newItem end
		if (next) then next[PREV] = newItem end
		if (prev == self.last)  then self.last  = newItem end
		if (next == self.first) then self.first = newItem end
		--return newItem
	end


	local function List_InsertItem(self, owner, data)
		local layer = owner._info.layer
		local item = self.first

		while (item) do
			if (item.owner == owner) then
				return --// already in table
			end

			if SortFuncExtension(owner._info, item.owner._info) then
				break
			end
			item = item[NEXT]
		end

		if (item) then
			List_InsertNewListItem(self, owner, data, item[PREV], item)
		else
			List_InsertNewListItem(self, owner, data, self.last, nil) --// end of the pack
		end

		return true
	end


	local function List_RemoveListItem(self, item)
		local prev = item[PREV]
		local next = item[NEXT]

		if (prev) then
			prev[NEXT] = next
		end
		if (next) then
			next[PREV] = prev
		end

		if (self.last == item) then
			self.last = prev
		end
		if (self.first == item) then
			self.first = next
		end
	end


	local function List_RemoveItem(self, owner)
		local item = self.first
		if (not item) then
			return --// list is empty
		end

		while (item) do
			if (item.owner == owner) then
				List_RemoveListItem(self, item)
				return true
			end
			item = item[NEXT]
		end
	end


	local function List_Iter(self, item)
		--// ATTENTION
		--// This iterator works fine when elements get removed during looping
		--// AS LONG AS you don't remove both the current and its succeeding one!!!
		if (item == nil) then
			item = self.first
		else
			item = item[NEXT]
		end
		if (item) then
			return item, item[DATA]
		else
			return nil
		end
	end


	local function List_GetIter(self, it)
		return List_Iter, self, it
	end


	local function List_ReverseIter(self, item)
		--// ATTENTION
		--// This iterator works fine when elements get removed during looping
		--// AS LONG AS you don't remove both the current and its succeeding one!!!
		if (item == nil) then
			item = self.last
		else
			item = item[PREV]
		end
		if (item) then
			return item, item[DATA]
		else
			return nil
		end
	end


	local function List_GetReverseIter(self, it)
		return List_ReverseIter, self, it
	end

	CreateList = function(name)
		return {
			name   = name,
			first  = nil,
			last   = nil,
			Insert = List_InsertItem,
			Remove = List_RemoveItem,
			iter     = List_GetIter,
			rev_iter = List_GetReverseIter,
		}
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  the handler object
--

handler = {
	name = "widgetHandler";

	verbose = true;
	autoUserWidgets = true; --FIXME rename

	widgets      = CreateList("widgets"); --// all loaded widgets
	configData   = {};
	orderList    = {};
	knownWidgets = {};
	knownChanged = 0;

	commands          = {}; --FIXME where used?
	customCommands    = {};
	inCommandsChanged = false;

	EG = EG;      --// engine global (all published funcs by the engine)
	SG = {};      --// shared table for widgets
	globals = {}; --// global vars/funcs

	knownCallIns    = {};
	callInLists     = setmetatable({}, {__index = function(self, key) self[key] = CreateList(key); return self[key]; end});
	callInHookFuncs = {};

	mouseOwner  = nil;
	initialized = false;
}

--// backward compability, so you can still call handler:UnitCreated() etc.
setmetatable(handler, {__index = function(self, key)
	local firstChar = key:sub(1,1)
	if (firstChar == firstChar:upper()) then
		return function(_, ...)
			if (self.callInHookFuncs[key]) then
				return self.callInHookFuncs[key](...)
			end
		end
	end
end})


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  Create list of known CallIns
--

--// always register those callins even when not used by any widget
local staticCallInList = {
	'ConfigureLayout',
	'Shutdown',
	'Update',
}

for _,ciName in ipairs(staticCallInList) do
	staticCallInList[ciName] = true
end


--// Load all known engine callins
local engineCallIns = Script.GetCallInList() --// important!
--engineCallIns.ConfigureLayout = {unsynced = true, controller = true}
--engineCallIns.Shutdown = {unsynced = true, controller = false}


--// Create list of all known callins (any others used in widgets won't work!)
local knownCallIns = handler.knownCallIns
for ciName,ciParams in pairs(engineCallIns) do
	if (ciParams.controller and (not ciParams.unsynced) and (not Script.GetSynced())) then
		--// skip synced only events when we are in an unsynced env.
	else
		knownCallIns[ciName] = ciParams
	end
end

--// Register custom (non-engine) callins
knownCallIns.Initialize = {}       --// ()
knownCallIns.WidgetAdded = {}      --// (wname)
knownCallIns.WidgetRemoved = {}    --// (wname, reason) -- reason can either be "crash" | "user" | "auto"
knownCallIns.SelectionChanged = {} --// (selection = {unitID1, unitID1}) -> [newSelection]
knownCallIns.CommandsChanged = {}  --// ()
knownCallIns.TextCommand = {}      --// ("command") -- renamed ConfigureLayout

function handler:AddKnownCallIn(ciName, unsynced, controller)
	if (knownCallIns[ciName]) then
		return
	end
	knownCallIns[ciName] = {unsynced = unsynced, controller = controller}
	for _,w in self.widgets:iter() do
		handler:UpdateWidgetCallIn(ciName, w)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Custom iterator for all known callins

local function knownCallins_iter(w, key)
	local ciFunc
	repeat
		key = next(knownCallIns, key)
		if (key) then
			ciFunc = w[key]
			if (type(ciFunc) == "function") then
				return key, ciFunc
			end
		end
	until (not key)
end

local function knownCallins(w)
	return knownCallins_iter, w, nil
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Initialize

function handler:Initialize()
	--// Create the "LuaUI/Config" directory
	Spring.CreateDir(LUAUI_DIRNAME .. 'Config')
	self:UpdateWidgetList()
	self.initialized = true
end


function handler:UpdateWidgetList()
	self:LoadOrderList()
	self:LoadConfigData()
	self:LoadKnownData()

	--// GetInfo() of new/changed files
	self:SearchForNew()

	--// Create list all to load files
	spEcho(LUA_NAME .. ": Loading Widgets   <>=vfs  **=raw  ()=unknown")
	self:DetectEnabledWidgets()

	local loadList = {}
	for name,order in pairs(self.orderList) do
		if (order > 0) then
			local ki = self.knownWidgets[name]
			if ki then
				loadList[#loadList+1] = name
			else
				if (self.verbose) then spEcho("Couldn't find a widget named \"" .. name .. "\"") end
				self.knownWidgets[name] = nil
				self.orderList[name] = nil
			end
		end
	end

	--// Sort them
	local SortFunc = function(n1, n2)
		local wi1 = handler.knownWidgets[n1]
		local wi2 = handler.knownWidgets[n2]
		--assert(wi1 and wi2)
		return SortFuncExtension(wi1 or emptyTable, wi2 or emptyTable)
	end
	table.sort(loadList, SortFunc)

	if (not self.verbose) then
		--// if not in verbose mode, print the to be load widgets (in a nice table) BEFORE loading them!
		local st = {}
		for _,name in ipairs(loadList) do
			st[#st+1] = self:GetFancyString(name)
		end
		tprinttable(st, 4)
	end

	--// Load them
	for _,name in ipairs(loadList) do
		local ki = self.knownWidgets[name]
		self:Load(ki.filepath)
	end

	--// Save the active widgets, and their ordering
	self:SaveOrderList()
	self:SaveConfigData()
	self:SaveKnownData()
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Widget Files Finder

local function GetAllWidgetFiles()
	local widgetFiles = {}
	for i,dir in pairs(WIDGET_DIRS) do
		spEcho(LUA_NAME .. " Scanning: " .. dir)
		local files = VFS.DirList(dir, "*.lua", VFSMODE)
		if (files) then
			tappend(widgetFiles, files)
		end
	end
	return widgetFiles
end


function handler:FindNameByPath(path)
	for _,ki in pairs(self.knownWidgets) do
		if (ki.filepath == path) then
			return ki.name
		end
	end
end


function handler:SearchForNew(quiet)
	if (quiet) then spEcho = function() end end
	spEcho(LUA_NAME .. ": Searching for new Widgets")

	local widgetFiles = GetAllWidgetFiles()
	for _,fpath in ipairs(widgetFiles) do
		local name = handler:FindNameByPath(fpath)
		local ki = name and self.knownWidgets[name]

		if not self.initialized then --// don't override the knownWidgets[name] of _loaded_ widgets!
			if ki and ki.checksum then --// rev2 widgets don't save a checksum!
				local checksum = VFS.GetFileChecksum(fpath, VFSMODE)
				if (checksum and (ki.checksum ~= checksum)) then
					ki = nil
				end
			end
		end

		if (not ki) then
			if (self.verbose) then spEcho(LUA_NAME .. ": Found new Widget \"" .. fpath .. "\"") end
			if name then self.knownWidgets[name] = nil end

			self:LoadWidgetInfo(fpath)
		end
	end

	self:DetectEnabledWidgets()
	if (quiet) then spEcho = Spring.Echo end
end


function handler:DetectEnabledWidgets()
	for i,ki in pairs(self.knownWidgets) do
		if (not ki.active) then
			--// default enabled?
			local defEnabled = ki.enabled

			--// enabled or not?
			local order = self.orderList[ki.name]
			if ((order or 0) > 0)
				or ((order == nil) and defEnabled and (self.autoUserWidgets or ki.fromZip))
			then
				--// this will be an active widget
				self.orderList[ki.name] = order or 1235 --// back of the pack for unknown order

				--//we don't auto start widgets when just updating the available list
				ki.active = (not self.initialized)
			else
				--// deactive the widget
				self.orderList[ki.name] = 0
				ki.active = false
			end
		end
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Widget Crash Handlers

local SafeCallWidget
local SafeWrapFunc

do
	--// small helper
	local isDrawCallIn = setmetatable({}, {__index = function(self,ciName)
		self[ciName] = ((ciName:sub(1, 4) == 'Draw')or(ciName:sub(1, 9) == 'TweakDraw'));
		return self[ciName];
	end})


	local function HandleError(widget, funcName, status, ...)
		if (status) then
			--// no error
			return ...
		end

		handler:Remove(widget, "crash")

		local name = widget._info.name
		local err  = select(1,...)
		spEcho('Error in ' .. funcName ..'(): ' .. tostring(err))
		spEcho('Removed widget: ' .. handler:GetFancyString(name))
		return nil
	end


	local function HandleErrorGL(widget, funcName, status, ...)
		glPopAttrib()
		--gl.PushMatrix()
		return HandleError(widget, funcName, status, ...)
	end


	local function SafeWrapFuncNoGL(w, func, funcName)
		return function(...)
			return HandleError(w, funcName, pcall(func, ...))
		end
	end


	local function SafeWrapFuncGL(w, func, funcName)
		return function(...)
			glPushAttrib()
			--gl.PushMatrix()
			return HandleErrorGL(w, funcName, pcall(func, ...))
		end
	end


	SafeWrapFunc = function(widget, func, funcName)
		if (SAFEWRAP <= 0) then
			return func
		elseif (SAFEWRAP == 1) then
			if (widget._info.unsafe) then
				return func
			end
		end

		if (not SAFEDRAW) then
			return SafeWrapFuncNoGL(widget, func, funcName)
		else
			if (isDrawCallIn[funcName]) then
				return SafeWrapFuncGL(widget, func, funcName)
			else
				return SafeWrapFuncNoGL(widget, func, funcName)
			end
		end
	end


	SafeCallWidget = function(w, ciName, ...)
		local f = w[ciName]
		if (not f) then
			return
		end

		local wi = w._info
		if (SAFEWRAP <= 0)or
			((SAFEWRAP == 1)and(wi and wi.unsafe))
		then
			return f(w, ...)
		end

		if (SAFEDRAW and isDrawCallIn[ciName]) then
			glPushAttrib()
			return HandleErrorGL(w, ciName, pcall(f, w, ...))
		else
			return HandleError(w, ciName, pcall(f, w, ...))
		end
	end
end

--// so widgets can use it, too
handler.SafeCallWidget = SafeCallWidget


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Callin Closures

local function InsertWidgetCallIn(ciName, widget)
	if (knownCallIns[ciName]) then
		local f = widget[ciName]

		--// use callInName__ to respect when a widget dislinked the function via :RemoveWidgetCallIn (and there is is still a func named widget[callInName])
		widget[ciName .. "__"] = f --// non closure!

		if ((widget._info._rev or 0) <= 1) then
			--// old widgets had widget:CallInXYZ, so we need to pass the widget as self object
			local f_ = f
			f = function(...) return f_(widget, ...) end
		end

		local swf = SafeWrapFunc(widget, f, ciName)
		return handler.callInLists[ciName]:Insert(widget, swf)
	elseif (handler.verbose) then
		spEcho(LUA_NAME .. "::InsertWidgetCallIn: Unknown CallIn \"" .. ciName.. "\"")
	end
	return false
end


local function RemoveWidgetCallIn(ciName, widget)
	if (knownCallIns[ciName]) then
		widget[ciName .. "__"] = nil
		return handler.callInLists[ciName]:Remove(widget)
	elseif (handler.verbose) then
		spEcho(LUA_NAME .. "::RemoveWidgetCallIn: Unknown CallIn \"" .. ciName.. "\"")
	end
	return false
end


local function RemoveWidgetCallIns(widget)
	for ciName,ciList in pairs(handler.callInLists) do
		ciList:Remove(widget)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Widget Info

function handler:LoadWidgetInfo(filepath, _VFSMODE)
	local err, wi = self:LoadWidgetRev2Info(filepath, _VFSMODE)
	if (err == true) then
		return nil --// widget asked for a silent death
	end
	if (not wi) then
		--// try to load it as rev1 widget
		local widget = self:ParseWidgetRev1(filepath, _VFSMODE)
		if (widget) then
			err, wi = self:LoadWidgetRev1Info(widget, filepath)
		end
	end

	if (not wi) then return nil end

	if (wi._rev <= 1) then
		wi.checksum = VFS.GetFileChecksum(wi.filepath, _VFSMODE or VFSMODE)
	end

	err = self:ValidateKnownInfo(wi, _VFSMODE)
	if (err) then
		spEcho(err)
		return nil
	end

	return wi
end


function handler:LoadWidgetRev2Info(filepath, _VFSMODE)
	local basename = Basename(filepath)

	local wi = {
		filepath = filepath,
		basename = basename,
		name     = basename,
		version  = "0.1",
		layer    = 0,
		desc     = "",
		author   = "",
		license  = "",
		enabled  = false,
		api      = false,
		handler  = false,
		before   = {},
		after    = {},
		_rev     = 2,
	}

	_VFSMODE = _VFSMODE or VFSMODE
	local basename = Basename(filepath)

	local loadEnv = {INFO = true; math = math}

	local success, rvalue = pcall(VFS.Include, filepath, loadEnv, _VFSMODE)
		if not success then
			return "Failed to load: " .. basename .. "  (" .. rvalue .. ")"
		end
		if rvalue == false then
			return true --// widget asked for a silent death
		end
		if type(rvalue) ~= "table" then
			return "Wrong return value: " .. basename
		end

	CopyTable(wi, rvalue)
	return false, wi
end


function handler:LoadWidgetRev1Info(widget, filepath)
	local basename = Basename(filepath)

	local wi = {
		filepath = filepath,
		basename = basename,
		name     = basename,
		version  = "0.1",
		layer    = 0,
		desc     = "",
		author   = "",
		license  = "",
		enabled  = false,
		api      = false,
		handler  = false,
		before   = {},
		after    = {},
		_rev     = 1,
	}

	if (widget.GetInfo) then
		local info = SafeCallWidget(widget, "GetInfo")
		if type(rvalue) ~= "table" then
			return "Failed to call GetInfo() in: " .. basename
		else
			CopyTable(wi, info)
		end
	end

	return false, wi
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Widget Parsing

function handler:NewWidgetRev2()
	local widgetEnv = {}
	local widget = widgetEnv
	widgetEnv.widget = widget  --// makes `function Initizalize` & `function widget.Initialize` point to the same data

	--// copy the engine enviroment to the widget
		CopyTable(widgetEnv, EG)
	--// the shared table
		widgetEnv.SG = self.SG
	--// insert handler
		widgetEnv.handler = handler
		widgetEnv[handler.name] = handler
	return widgetEnv
end


function handler:ParseWidgetRev2(filepath, _VFSMODE)
	_VFSMODE = _VFSMODE or VFSMODE
	local basename = Basename(filepath)

	--// load the code
	local widgetEnv = self:NewWidgetRev2()
	local success, err = pcall(VFS.Include, filepath, widgetEnv, _VFSMODE)
	if (not success) then
		spEcho('Failed to load: ' .. basename .. '  (' .. err .. ')')
		return nil
	end
	if (err == false) then
		return nil --// widget asked for a silent death
	end

	local widget = widgetEnv.widget

	--// Validate Callins
	err = self:ValidateWidget(widget)
	if (err) then
		spEcho('Failed to load: ' .. basename .. '  (' .. err .. ')')
		return nil
	end

	return widget
end


function handler:ParseWidgetRev1(filepath, _VFSMODE)
	_VFSMODE = _VFSMODE or VFSMODE
	local basename = Basename(filepath)

	--// load the code
	local widgetEnv = self:NewWidgetRev1()
	local success, err = pcall(VFS.Include, filepath, widgetEnv, _VFSMODE)
	if (not success) then
		spEcho('Failed to load: ' .. basename .. '  (' .. err .. ')')
		return nil
	end
	if (err == false) then
		return nil --// widget asked for a silent death
	end

	local widget = widgetEnv.widget

	--// Validate Callins
	err = self:ValidateWidget(widget)
	if (err) then
		spEcho('Failed to load: ' .. basename .. '  (' .. err .. ')')
		return nil
	end

	return widget
end


function handler:NewWidgetRev1()
	local widgetEnv = {}
	local widget = widgetEnv --// easy self referencing
	widgetEnv.widget = widget

	--// copy the engine enviroment to the widget
	CopyTable(widgetEnv, EG)
	
	--// the shared table
	--widgetEnv.SG = self.SG
	widgetEnv.WG = self.SG

	--// wrapped calls (closures)
	local h = {}
	widgetEnv.handler = h
	widgetEnv[handler.name] = h
	widgetEnv.include = function(f) return include(f, widget) end
	h.ForceLayout  = handler.ForceLayout
	h.RemoveWidget = function() handler:Remove(widget, "auto") end
	h.GetCommands  = function() return handler.commands end
	h.GetViewSizes = handler.GetViewSizes
	h.GetHourTimer = handler.GetHourTimer
	h.IsMouseOwner = function() return (handler.mouseOwner == widget) end
	h.DisownMouse  = function()
		if (handler.mouseOwner == widget) then
			handler.mouseOwner = nil
		end
	end

	h.UpdateCallIn = function(_, name) handler:UpdateWidgetCallIn(name, widget) end
	h.RemoveCallIn = function(_, name) handler:RemoveWidgetCallIn(name, widget) end

	h.AddAction    = function(_, cmd, func, data, types)
		return actionHandler.AddWidgetAction(widget, cmd, func, data, types)
	end
	h.RemoveAction = function(_, cmd, types)
		return actionHandler.RemoveWidgetAction(widget, cmd, types)
	end

	h.AddLayoutCommand = function(_, cmd)
		if (handler.inCommandsChanged) then
			table.insert(handler.customCommands, cmd)
		else
			spEcho("AddLayoutCommand() can only be used in CommandsChanged()")
		end
	end
	h.ConfigLayoutHandler = handler.ConfigLayoutHandler

	h.RegisterGlobal   = function(_, name, value) return handler:RegisterGlobal(widget, name, value) end
	h.DeregisterGlobal = function(_, name)        return handler:DeregisterGlobal(widget, name) end
	h.SetGlobal        = function(_, name, value) return handler:SetGlobal(widget, name, value) end

	return widgetEnv
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function handler:ValidateKnownInfo(ki, _VFSMODE)
	if not ki then
		return "No KnownInfo given"
	end

	--// load/create data
	local knownInfo = self.knownWidgets[ki.name]
	if (not knowInfo) then
		knownInfo = {}
		self.knownWidgets[ki.name] = knownInfo
	end

	--// check for duplicated name
	if (knownInfo.filepath)and(knownInfo.filepath ~= ki.filepath) then
		return "Failed to load: " .. ki.basename .. " (duplicate name)"
	end

	--// create/update a knownInfo table
	CopyTable(knownInfo, ki) --// update table

	--// check if it is loaded from a zip (game or map)
	knownInfo.fromZip = true
	if (_VFSMODE == VFS.ZIP_FIRST) then
		knownInfo.fromZip = VFS.FileExists(ki.filepath,VFS.ZIP_ONLY)
	else
		knownInfo.fromZip = not VFS.FileExists(ki.filepath,VFS.RAW_ONLY)
	end

	--// update so widgets can see if something got changed
	self.knownChanged = self.knownChanged + 1
end


function handler:ValidateWidget(widget)
	if (widget.GetTooltip and not widget.IsAbove) then
		return "Widget has GetTooltip() but not IsAbove()"
	end
	return nil
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function handler:GetFancyString(name, str)
	if not str then str = name end
	local ki = self.knownWidgets[name]
	if ki then
		if ki.fromZip then
			return ("<%s>"):format(str)
		else
			return ("*%s*"):format(str)
		end
	else
		return ("(%s)"):format(str)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function handler:Load(filepath, _VFSMODE)
	--FIXME handler:AllowWidgetLoading(filepath)

	--// Load KnownInfo
	local name = self:FindNameByPath(filepath)
	local ki = name and self.knownWidgets[name]
	if (not ki)or((ki._rev or 0) < 2) then
		self:LoadWidgetInfo(filepath, _VFSMODE)
		ki = name and self.knownWidgets[name]
	end
	if (not ki) then
		return
	end

	--// Load Widget
	local widget
	if ((ki._rev or 0) >= 2) then
		widget = self:ParseWidgetRev2(filepath, _VFSMODE)
	else
		widget = self:ParseWidgetRev1(filepath, _VFSMODE)
	end
	if (not widget) then
		return
	end

	--// Link KnownInfo with widget
	local mt = {
		__index = ki,
		__newindex = function() error("_info tables are read-only") end,
		__metatable = "protected"
	}
	widget._info = setmetatable({}, mt)
	widget.whInfo = widget._info --//backward compability

	--// Verbose
	local name = widget._info.name
	local basename = widget._info.basename

	if (self.verbose or self.initialized) then
		local loadingstr = "Loading widget: " .. ((self.initialized and "") or "    ") --// the concat is done to align it with the api string! (the one beneath)
		if (ki.api) then
			loadingstr = "Loading API widget: "
		end
		spEcho(("%s %-21s  %s"):format(loadingstr, name, self:GetFancyString(name,basename)))
	end

	--// Add to handler
	ki.active = true
	self.widgets:Insert(widget, widget)

	--// Unsafe widget (don't use pcall for callins)
	if (SAFEWRAP == 1)and(widget._info.unsafe) then
		spEcho(LUA_NAME .. ': loaded unsafe widget: ' .. name)
	end

	--// Link the CallIns
	for ciName,ciFunc in knownCallins(widget) do
		InsertWidgetCallIn(ciName, widget)
	end
	self:UpdateCallIns()

	--// Raw access to the handler
	if (ki.handler) then --FIXME rev2
		widget.handler = self
		widget.widgetHandler = self
	end

	--// Initialize the widget
	if (widget.Initialize) then
		SafeCallWidget(widget, "Initialize")
	end

	--// Load the config data  
	local config = self.configData[name]
	if (widget.SetConfigData and config) then
		SafeCallWidget(widget, "SetConfigData", config)
	end

	--// inform other widgets
	handler:WidgetAdded(name)
end


function handler:Remove(widget, _reason)
	if not widget then
		widget = getfenv(2)
	end

	if (type(widget) ~= "table")or(type(widget._info) ~= "table")or(not widget._info.name) then
		error "Wrong input to handler:Remove()"
	end

	--// Try clean exit
	local name = widget._info.name
	local ki = self.knownWidgets[name]
	if (not ki.active) then
		return
	end
	ki.active = false
	self:SaveWidgetConfigData(widget)
	if (widget.Shutdown) then
		local ok, err = pcall(widget.Shutdown, widget)
		if not ok then
			spEcho('Error in Shutdown(): ' .. tostring(err))
		end
	end

	--// Remove any links in the handler
	self:RemoveWidgetGlobals(widget)
	actionHandler.RemoveWidgetActions(widget)
	self.widgets:Remove(widget)
	RemoveWidgetCallIns(widget)
	self:UpdateCallIns()

	--// inform other widgets
	handler:WidgetRemoved(name, _reason or "user")
end

--// backward compab.
handler.LoadWidget   = handler.Load
handler.RemoveWidget = handler.Remove

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Save/Load Widget related data

function handler:LoadOrderList()
	if VFS.FileExists(ORDER_FILENAME) then
		local success, rvalue = pcall(VFS.Include, ORDER_FILENAME, {math = {huge = math.huge}})
		if (not success) then
			spEcho(LUA_NAME .. ': Failed to load: ' .. ORDER_FILENAME .. '  (' .. rvalue .. ')')
		else
			self.orderList = rvalue
		end
	end
end


function handler:SaveOrderList()
	--// update the current order
	local i = 1
	for _,w in self.widgets:iter() do
		self.orderList[w._info.name] = i
		i = i + 1
	end
	table.save(self.orderList, ORDER_FILENAME, '-- Widget Order List  (0 disables a widget)')
end


function handler:LoadKnownData()
	if (handler.initialized) then --FIXME
		error "Called handler:LoadKnownData after Initialization."
	end

	if VFS.FileExists(KNOWN_FILENAME) then
		local success, rvalue = pcall(VFS.Include, KNOWN_FILENAME, {math = {huge = math.huge}})
		if (not success) then
			spEcho(LUA_NAME .. ': Failed to load: ' .. KNOWN_FILENAME .. '  (' .. rvalue .. ')')
		else
			self.knownWidgets = rvalue
		end
	end

	for i,ki in pairs(self.knownWidgets) do
		ki.active = nil

		--// Remove non-existing entries
		if not VFS.FileExists(ki.filepath or "", (ki.fromZip and VFS.ZIP_ONLY) or VFS.RAW_ONLY) then
			self.knownWidgets[i] = nil
		end
	end
end


function handler:SaveKnownData()
	local t = {}
	for i,v in pairs(self.knownWidgets) do
		if ((v._rev or 0) <= 1) then --// Don't save/cache rev2 widgets (there is no safety problem to get their info)
			t[i] = v
		end
	end

	table.save(t, KNOWN_FILENAME, '-- Filenames -> WidgetNames Translation Table')
end


function handler:LoadConfigData()
	if VFS.FileExists(CONFIG_FILENAME) then
		self.configData = VFS.Include(CONFIG_FILENAME, {})
	end
	self.configData = self.configData or {}
end


function handler:SaveWidgetConfigData(widget)
	if (widget.GetConfigData) then
		local name = widget._info.name 
		self.configData[name] = SafeCallWidget(widget, "GetConfigData")
	end
end


function handler:SaveConfigData()
	self:LoadConfigData()
	for _,w in self.widgets:iter() do
		self:SaveWidgetConfigData(w)
	end
	table.save(self.configData, CONFIG_FILENAME, '-- Widget Custom Data')
end


function handler:SendConfigData()
	self:LoadConfigData()
	for _,w in self.widgets:iter() do
		local data = self.configData[w._info.name]
		if (w.SetConfigData and data) then
			SafeCallWidget(w, "SetConfigData", data)
		end
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Enable/Disable/Toggle Widgets

function handler:FindByName(name)
	for _,w in self.widgets:iter() do
		if (w._info.name == name) then
			return w
		end
	end
end


function handler:Enable(name)
	local ki = self.knownWidgets[name]
	if (not ki) then
		spEcho(LUA_NAME .. "::Enable: Couldn\'t find \"" .. name .. "\".")
		return false
	end
	if (ki.active) then
		return false
	end

	local order = handler.orderList[name]
	if ((order or 0) <= 0) then
		self.orderList[name] = 1
	end
	self:Load(ki.filepath)
	self:SaveOrderList()
	return true
end


function handler:Disable(name)
	local ki = self.knownWidgets[name]
	if (not ki) then
		spEcho(LUA_NAME .. "::Disable: Didn\'t found \"" .. name .. "\".")
		return false
	end
	if (not ki.active)and((order or 0) > 0) then
		return false
	end

	local w = self:FindByName(name)
	if (w) then
		spEcho(("Removed widget:  %-21s  %s"):format(name, self:GetFancyString(name,ki.basename)))
		self:Remove(w)     --// deactivate
		self.orderList[name] = 0 --// disable
		self:SaveOrderList()
		return true
	else
		spEcho(LUA_NAME .. "::Disable: Didn\'t found \"" .. name .. "\".")
	end
end


function handler:Toggle(name)
	local ki = self.knownWidgets[name]
	if (not ki) then
		spEcho(LUA_NAME .. "::Toggle: Couldn\'t find \"" .. name .. "\".")
		return
	end

	if (ki.active) then
		return self:Disable(name)
	elseif (self.orderList[name] <= 0) then
		return self:Enable(name)
	else
		--// the widget is not active, but enabled; disable it
		self.orderList[name] = 0
		self:SaveOrderList()
	end
	return true
end

--// backward compab.
handler.FindWidgetByName = handler.FindByName
handler.EnableWidget     = handler.Enable
handler.DisableWidget    = handler.Disable
handler.ToggleWidget     = handler.Toggle

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Global var/func management

function handler:RegisterGlobal(owner, name, value)
	if (name == nil)        or
	   (_G[name])           or
	   (self.globals[name]) or
	   (engineCallIns[name])
	then
		return false
	end
	_G[name] = value
	self.globals[name] = owner
	return true
end


function handler:DeregisterGlobal(owner, name)
	if ((name == nil) or (self.globals[name] and (self.globals[name] ~= owner))) then
		return false
	end
	_G[name] = nil
	self.globals[name] = nil
	return true
end


function handler:SetGlobal(owner, name, value)
	if ((name == nil) or (self.globals[name] ~= owner)) then
		return false
	end
	_G[name] = value
	return true
end


function handler:RemoveWidgetGlobals(owner)
	local count = 0
	for name, o in pairs(self.globals) do
		if (o == owner) then
			_G[name] = nil
			self.globals[name] = nil
			count = count + 1
		end
	end
	return count
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Helper facilities

local hourTimer = 0

function handler:GetHourTimer()
	return hourTimer
end

function handler:GetViewSizes()
	return gl.GetViewSizes()
end

function handler:ForceLayout()
	forceLayout = true  --FIXME in main.lua
end

function handler:ConfigLayoutHandler(data)
	ConfigLayoutHandler(data)
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- CallIn Manager Functions

local function CreateHookFunc(ciName)
	local ciList = handler.callInLists[ciName]
	if (ciName:sub(1, 4) ~= 'Draw')and(ciName:sub(1, 9) ~= 'TweakDraw') then
		return function(...)
			for _,f in ciList:iter(it) do
				f(...)
			end
		end
	else
		return function(...)
			for _,f in ciList:rev_iter(it) do
				f(...)
			end
		end
	end
end


function handler:UpdateCallIn(ciName)
	--// known callin?
	if (not self.knownCallIns[ciName]) then
		return
	end

	--// always create the hook functions, so widgets can use them via e.g. handler:GetTooltip(x,y)
	local hookfunc = self.callInHookFuncs[ciName]
	if (not hookfunc) then
		hookfunc = CreateHookFunc(ciName)
		self.callInHookFuncs[ciName] = hookfunc
	end

	--// non-engine callins don't need to be exported to the engine
	if (not engineCallIns[ciName]) then
		return
	end

	local ciList = self.callInLists[ciName]

	if ((ciList.first) or
	    (staticCallInList[ciName]) or
	    ((ciName == 'GotChatMsg')     and actionHandler.HaveChatAction()) or  --FIXME these are LuaRules only
	    ((ciName == 'RecvFromSynced') and actionHandler.HaveSyncAction()))    --FIXME these are LuaRules only
	then
		--// already exists?
		if (type(_G[ciName]) == "function") then
			return
		end

		--// always assign these call-ins
		_G[ciName] = hookfunc
	else
		_G[ciName] = nil
	end
	Script.UpdateCallIn(ciName)
end


function handler:UpdateWidgetCallIn(name, w)
	local func = w[name]
	local result = false
	if (type(func) == 'function') then
		result = InsertWidgetCallIn(name, w)
	else
		result = RemoveWidgetCallIn(name, w)
	end
	if result then
		self:UpdateCallIn(name)
	end
end


function handler:RemoveWidgetCallIn(name, w)
	if RemoveWidgetCallIn(name, w) then
		self:UpdateCallIn(name)
	end
end


function handler:UpdateCallIns()
	for ciName in pairs(knownCallIns) do
		self:UpdateCallIn(ciName)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Some CallIns need custom handlers

local hCallInLists = handler.callInLists
local hHookFuncs   = handler.callInHookFuncs

function hHookFuncs.Shutdown()
	handler:SaveOrderList()
	handler:SaveConfigData()
	for _,f in hCallInLists.Shutdown:iter() do
		f()
	end
end


function hHookFuncs.ConfigureLayout(command)
	if (command == 'reconf') then
		handler:SendConfigData()
		return true
	elseif (command:find('togglewidget') == 1) then
		handler:Toggle(string.sub(command, 14))
		return true
	elseif (command:find('enablewidget') == 1) then
		handler:Enable(string.sub(command, 14))
		return true
	elseif (command:find('disablewidget') == 1) then
		handler:Disable(string.sub(command, 15))
		return true
	elseif (command:find('callins') == 1) then
		Spring.Echo(LUA_NAME .. ": known callins are:")
		Spring.Echo("  (NOTE: This list contains a few (e.g. cause of LOS checking) unhandled CallIns, too.)")
		local o = {}
		for i,v in pairs(knownCallIns) do
			local t = {}
			for j,w in pairs(v) do
				t[#t+1] = j .. "=" .. tostring(w)
			end
			o[#o+1] = ("  %-25s "):format(i .. ":") .. table.concat(t, ", ")
		end
		table.sort(o)
		for i=1,#o do
			Spring.Echo(o[i])
		end
		return true
	end

	if (actionHandler.TextAction(command)) then
		return true
	end

	for _,f in hCallInLists.TextCommand:iter() do
		if (f(command)) then
			return true
		end
	end

	return false
end


function hHookFuncs.Update()
	local deltaTime = Spring.GetLastUpdateSeconds()
	hourTimer = (hourTimer + deltaTime) % 3600

	for _,f in hCallInLists.Update:iter() do
		f(deltaTime)
	end
end


function hHookFuncs.CommandNotify(id, params, options)
	for _,f in hCallInLists.CommandNotify:iter() do
		if (f(id, params, options)) then
			return true
		end
	end

	return false
end


function hHookFuncs.CommandsChanged()
	handler:UpdateSelection() --// for selectionchanged
	handler.inCommandsChanged = true
	handler.customCommands = {}

	for _,f in hCallInLists.CommandsChanged:iter() do
		f()
	end

	handler.inCommandsChanged = false
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Drawing call-ins

function hHookFuncs.ViewResize(viewGeometry)
	local vsx = viewGeometry.viewSizeX
	local vsy = viewGeometry.viewSizeY
	for _,f in hCallInLists.ViewResize:iter() do
		f(vsx, vsy, viewGeometry)
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Keyboard call-ins

function hHookFuncs.KeyPress(key, mods, isRepeat, label, unicode)
	if (actionHandler.KeyAction(true, key, mods, isRepeat)) then
		return true
	end

	for _,f in hCallInLists.KeyPress:iter() do
		if f(key, mods, isRepeat, label, unicode) then
			return true
		end
	end

	return false
end


function hHookFuncs.KeyRelease(key, mods, label, unicode)
	if (actionHandler.KeyAction(false, key, mods, false)) then
		return true
	end

	for _,f in hCallInLists.KeyRelease:iter() do
		if f(key, mods, label, unicode) then
			return true
		end
	end

	return false
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Mouse call-ins

do
	local lastDrawFrame = 0
	local lastx,lasty = 0,0
	local lastWidget

	local spGetDrawFrame = Spring.GetDrawFrame

	--// local helper
	function handler:WidgetAt(x, y)
		local drawframe = spGetDrawFrame()
		if (lastDrawFrame == drawframe)and(lastx == x)and(lasty == y) then
			return lastWidget
		end

		lastDrawFrame = drawframe
		lastx = x
		lasty = y

		for it,f in hCallInLists.IsAbove:iter() do
			if f(x, y) then
				lastWidget = it.owner
				return lastWidget
			end
		end

		lastWidget = nil
		return nil
	end
end


function hHookFuncs.MousePress(x, y, button)
	local mo = handler.mouseOwner
	if (mo and mo.MousePress__) then
		SafeCallWidget(mo, "MousePress__", x, y, button)
		return true  --// already have an active press
	end

	for it,f in hCallInLists.MousePress:iter() do
		if f(x, y, button) then
			handler.mouseOwner = it.owner
			return true
		end
	end
	return false
end


function hHookFuncs.MouseMove(x, y, dx, dy, button)
	--FIXME send this event to all widgets (perhaps via a new callin PassiveMouseMove?)

	local mo = handler.mouseOwner
	if (mo) then
		return SafeCallWidget(mo, "MouseMove__", x, y, dx, dy, button)
	end
end


function hHookFuncs.MouseRelease(x, y, button)
	local mo = handler.mouseOwner
	local mx, my, lmb, mmb, rmb = Spring.GetMouseState()
	if (not (lmb or mmb or rmb)) then
		handler.mouseOwner = nil
	end

	if (not mo) then
		return -1
	end

	return SafeCallWidget(mo, "MouseRelease__", x, y, button) or -1
end


function hHookFuncs.MouseWheel(up, value)
	for _,f in hCallInLists.MouseWheel:iter() do
		if (f(up, value)) then
			return true
		end
	end
	return false
end


function hHookFuncs.IsAbove(x, y)
	return (handler:WidgetAt(x, y) ~= nil)
end


function hHookFuncs.GetTooltip(x, y)
	for it,f in hCallInLists.GetTooltip:iter() do
		if (SafeCallWidget(it.owner, "IsAbove__", x, y)) then
			local tip = f(x, y)
			if ((type(tip) == 'string') and (#tip > 0)) then
				return tip
			end
		end
	end
	return ""
end



--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  Game call-ins

function hHookFuncs.WorldTooltip(ttType, ...)
	for _,f in hCallInLists.WorldTooltip:iter() do
		local tt = f(ttType, ...)
		if ((type(tt) == 'string') and (#tt > 0)) then
			return tt
		end
	end
end


function hHookFuncs.MapDrawCmd(playerID, cmdType, px, py, pz, ...)
	local retval = false
	for _,f in hCallInLists.MapDrawCmd:iter() do
		local takeEvent = f(playerID, cmdType, px, py, pz, ...)
		if (takeEvent) then
			retval = true
		end
	end
	return retval
end


function hHookFuncs.GameSetup(state, ready, playerStates)
	for _,f in hCallInLists.GameSetup:iter() do
		local success, newReady = f(state, ready, playerStates)
		if (success) then
			return true, newReady
		end
	end
	return false
end


function hHookFuncs.DefaultCommand(...)
	for _,f in hCallInLists.DefaultCommand:iter() do
		local result = f(...)
		if (type(result) == 'number') then
			return result
		end
	end
	return nil  --// not a number, use the default engine command
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--  RecvLuaMsg

function hHookFuncs.RecvLuaMsg(msg, playerID)
	local retval = false
	for _,f in hCallInLists.RecvLuaMsg:iter() do
		if (f(msg, playerID)) then
			retval = true
		end
	end
	return retval  --FIXME: another actionHandler type?
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Custom SelectionChanged callin

--// local helper
local oldSelection = {}
function handler:UpdateSelection()
	local changed = false
	local newSelection = Spring.GetSelectedUnits()
	if (#newSelection == #oldSelection) then
		for i=1, #newSelection do
			if (newSelection[i] ~= oldSelection[i]) then --// it seems the order stays
				changed = true
				break
			end
		end
	else
		changed = true
	end
	if (changed) then
		handler:SelectionChanged(newSelection)
	end
	oldSelection = newSelection
end


function hHookFuncs.SelectionChanged(selectedUnits)
	for _,f in hCallInLists.SelectionChanged:iter() do
		local unitArray = f(selectedUnits)
		if (unitArray) then
			Spring.SelectUnitArray(unitArray)
			selectedUnits = unitArray
		end
	end
end


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Start

--// Load game's configfile for this handler
include("config.lua", nil, VFS.ZIP_FIRST)

handler:Initialize()

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
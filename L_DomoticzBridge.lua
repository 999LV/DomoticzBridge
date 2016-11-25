ABOUT = {
  NAME          = "DomoticzBridge",
  VERSION       = "0.13",
  DESCRIPTION   = "DomoticzBridge plugin for openLuup, based on VeraBridge",
  AUTHOR        = "@logread, based on code from @akbooer",
  COPYRIGHT     = "(c) 2016 logread",
  DOCUMENTATION = "https://github.com/999LV/DomoticzBridge/blob/master/README.md",
}
--[[

bi-directional monitor/control link to remote Domoticz system
it is based on @Akbooer's VeraBridge plugin, modified as follows

NB. this version ONLY works in openLuup
	it plays with action calls and device creation in ways that you can't do in Vera,
	in order to be able to implement ANY command action and
	also to logically group device numbers for remote machine device clones.

	2016-08-06	alpha version 0.01 to prove concept
	2016-08-19	alpha version 0.05 functional with basic test set of devices
	2016-08-20	alpha verison 0.06 simplify translation of luup actions into Domoticz API calls
								   added dimmer device - still debug needed though
	2016-08-21	alpha version 0.07 improved actions code - dimmer device and PushOnButton bugs corrected
	2016-08-21	alpha version 0.08 smoke sensor and tripped info for both smoke and motion sensors
	2016-08-22	alpha version 0.09 major change to device creation... add all default variables, not just the ones cloned from Domoticz
	2016-08-26	alpha version 0.10 code optimization and cleanup for Domoticz API calls
	2016-08-26	alpha version 0.11 WIP: variable change function to address some device actions (e.g. security sensors armed/tripped)
	2016-08-31	alpha version 0.12 first public release on Alt App Store
  2016-11-24  beta version 0.13 - bug fix for dimmers/blinds level

This program is free software: you can redistribute it and/or modify
it under the condition that it is for private or home useage and
this whole comment is reproduced in the source code file.
Commercial utilisation is not authorized without the appropriate
written agreement from "logread", contact by PM on http://forum.micasaverde.com/
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

-]]
local devNo                      -- our device number
local DZport	= "8084"	-- default port of the Domoticz server

local chdev		= require "openLuup.chdev"
local json		= require "openLuup.json"
local rooms		= require "openLuup.rooms"
local scenes	= require "openLuup.scenes"
local userdata	= require "openLuup.userdata"
local url		= require "socket.url"
local lfs		= require "lfs"
local loader	= require "openLuup.loader" -- thank @akbooer for the hint about device file info
local http		= require "socket.http"

local SID_DZB = "urn:upnp-org:serviceId:DomoticzBridge:1"
local pollmap = {} -- bi-directional index for local/remote variables polling loop and update handlers
local actionmap = {} -- bi-directional index for device actions

local ip                          -- remote machine ip address
local POLL_DELAY = 60             -- number of seconds between remote polls

local local_room_index           -- bi-directional index of our rooms
local remote_room_index          -- bi-directional of remote rooms

local BuildVersion                -- ...of remote machine

local SID = {
  altui    = "urn:upnp-org:serviceId:altui1"  ,         -- Variables = 'DisplayLine1' and 'DisplayLine2'
  gateway  = "urn:upnp-org:serviceId:DomoticzBridge:1", --"urn:akbooer-com:serviceId:VeraBridge1",
  hag      = "urn:micasaverde-com:serviceId:HomeAutomationGateway1",
}

local Mirrored          -- mirrors is a set of device IDs for 'reverse bridging', not to be cloned
local MirrorHash        -- reverse lookup: local hash to remote device ID
local HouseModeMirror   -- flag with one of the following options
local HouseModeTime = 0 -- last time we checked

local HouseModeOptions = {      -- 2016.05.23
  ['0'] = "0 : no mirroring",
  ['1'] = "1 : local mirrors remote",
  ['2'] = "2 : remote mirrors local",
}


-- @explorer options for device filtering

local ZWaveOnly, Included, Excluded

--[[ 	the DZ2VeraMap allows matching a given (known) Domoticz device type/subtype with the closest possible device type in openLuup.
		the device_file key is used to create the relevant device (a call to openLuup's loader module gathers the other required data);
		the states table is mapping the Domoticz variables to the appropriate openLuup ones. For now, there is no attempt to create/use
		any other services/variables than the ones in this table
--]]
local DZ2VeraMap = {
	Temp = {
		device_file = "D_TemperatureSensor1.xml",
		states = {
			{service = "urn:upnp-org:serviceId:TemperatureSensor1", variable = "CurrentTemperature", DZData = "Temp"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:upnp-org:serviceId:TemperatureSensor1",
			action = "SetVariable", name = "CurrentTemperature",
			command = "udevice&idx=%d&nvalue=0&svalue=%d" }
		}
	},
	Humidity = {
		device_file = "D_HumiditySensor1.xml",
		states = {
			{service = "urn:micasaverde-com:serviceId:HumiditySensor1", variable = "CurrentLevel", DZData = "Humidity"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:micasaverde-com:serviceId:HumiditySensor1",
			action = "SetVariable", name = "CurrentLevel",
			command = "udevice&idx=%d&nvalue=%d&svalue=0"} -- need to be tested... nvalue with % or not ? svalue can be "" ?
		}
	},
	TempHumidityBaro = { -- original data = "Temp + Humidity + Baro"
		device_file = "D_ComboDevice1.xml",
		states = {
			{service = "urn:upnp-org:serviceId:TemperatureSensor1", variable = "CurrentTemperature", DZData = "Temp"},
			{service = "urn:micasaverde-com:serviceId:HumiditySensor1", variable = "CurrentLevel", DZData = "Humidity"},
			{service = "urn:upnp-org:serviceId:altui1", variable = "DisplayLine1", DZData = "Data"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		}
	},
	SwitchOnOff = { -- original data = "Light/Switch", with SubType to be refined
		device_file = "D_BinaryLight1.xml",
		states = {
			{service = "urn:upnp-org:serviceId:SwitchPower1", variable = "Status", DZData = "Status", boolean = true},
--			{service = "urn:upnp-org:serviceId:SwitchPower1", variable = "Target", DZData = "Status", boolean = true},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:upnp-org:serviceId:SwitchPower1",
			action = "SetTarget", name = "newTargetValue",
			command = "switchlight&idx=%d&switchcmd=%s", boolean = true}
		}
	},
	PushOnButton = { -- original data = "Lighting 2", with SubType = "AC" and SwitchType = "Push On Button"
		device_file = "D_BinaryLight1.xml",
		states = {
			{service = "urn:upnp-org:serviceId:SwitchPower1", variable = "Status", DZData = "Data", boolean = true},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:upnp-org:serviceId:SwitchPower1",
			action = "SetTarget", name = "newTargetValue",
			command = "switchlight&idx=%d&switchcmd=%s", boolean = true}
		}
	},
	Dimmer = { -- original data = ""Light/Switch", with SubType = "Selector Switch" and SwitchType = "Dimmer"
		device_file = "D_DimmableLight1.xml",
		states = {
      {service = "urn:upnp-org:serviceId:Dimming1", variable = "LoadLevelTarget", DZData = "Level"},
      {service = "urn:upnp-org:serviceId:Dimming1", variable = "LoadLevelStatus", DZData = "Level"},
			{service = "urn:upnp-org:serviceId:SwitchPower1", variable = "Status", DZData = "Status", boolean = true},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:upnp-org:serviceId:Dimming1",
			action = "SetLoadLevelTarget", name = "newLoadlevelTarget",
			command = "switchlight&idx=%d&switchcmd=Set%%20Level&level=%d"},
			{service = "urn:upnp-org:serviceId:SwitchPower1",
			action = "SetTarget", name = "newTargetValue",
			command = "switchlight&idx=%d&switchcmd=%s", boolean = true}
		}
	},
	Blinds = { -- original data = ""Light/Switch", with SubType = "Switch" and SwitchType includes "Blinds"
		device_file = "D_WindowCovering1.xml",
		states = {
			{service = "urn:upnp-org:serviceId:SwitchPower1", variable = "Status", DZData = "Status", boolean = true},
			{service = "urn:upnp-org:serviceId:Dimming1", variable = "LoadLevelStatus", DZData = "Level"},
      {service = "urn:upnp-org:serviceId:Dimming1", variable = "LoadLevelTarget", DZData = "Level"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:upnp-org:serviceId:Dimming1",
			action = "SetLoadLevelTarget", name = "newLoadlevelTarget",
			command = "switchlight&idx=%d&switchcmd=%s", boolean = true, inverted = true}, -- &level=0
--			{service = "urn:upnp-org:serviceId:Dimming1",
--			action = "SetLoadLevelTarget", name = "newLoadlevelTarget",
--			command = "switchlight&idx=%d&switchcmd=Set%%20Level&level=%d"},
			{service = "urn:upnp-org:serviceId:WindowCovering1",
			action = "Stop", name = "",
			command = "switchlight&idx=%d&switchcmd=Stop"} -- &level=0
		}
	},
	MotionSensor = { -- original Type = "Light/Switch" with SubType = "Switch" and SwitchType = "Motion Sensor"
		device_file = "D_MotionSensor1.xml",
		states = {
			{service = "urn:micasaverde-com:serviceId:SecuritySensor1", variable = "Tripped", DZData = "Status", boolean = true},
--			{service = "urn:micasaverde-com:serviceId:SecuritySensor1", variable = "LastTrip", DZData = "LastUpdate", epoch = true},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:micasaverde-com:serviceId:SecuritySensor1",
			action = "SetArmed", name = "newArmedValue",
			command = "Armed", self = true}
		}
	},
	SmokeDetector = { -- original Type = "Light/Switch" with SubType = "Switch" and SwitchType = "Smoke Detector"
		device_file = "D_SmokeSensor1.xml",
		states = {
			{service = "urn:micasaverde-com:serviceId:SecuritySensor1", variable = "Tripped", DZData = "Status", boolean = true},
--			{service = "urn:micasaverde-com:serviceId:SecuritySensor1", variable = "LastTrip", DZData = "LastUpdate", epoch = true},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		},
		actions = {
			{service = "urn:micasaverde-com:serviceId:SecuritySensor1",
			action = "SetArmed", name = "newArmedValue",
			command = "Armed", self = true}
		}
	},
	Lux = {
		device_file = "D_LightSensor1.xml",
		states = {
			{service = "urn:micasaverde-com:serviceId:LightSensor1", variable = "CurrentLevel", DZData = "Data", pattern = "[^%d]"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		}
	},
	Generic = {
		device_file = "D_GenericSensor1.xml",
		states = {
			{service = "urn:micasaverde-com:serviceId:GenericSensor1", variable = "CurrentLevel", DZData = "Data"},
			{service = "urn:upnp-org:serviceId:altui1", variable = "DisplayLine1", DZData = "Data"},
			{service = "urn:micasaverde-com:serviceId:HaDevice1", variable = "BatteryLevel", DZData = "BatteryLevel"}
		}
	}
}
--------------------------------------------------------------------------------------------------


-- Logread's utility functions


local function nicelog(message)
	local display = "Domoticz Bridge : %s"
	message = message or ""
	if type(message) == "table" then message = table.concat(message) end
	luup.log(string.format(display, message))
--	print(string.format(display, message))
end

-- shallow-copy a table
local function tablecopy(t)
    if type(t) ~= "table" then return t end
    local meta = getmetatable(t)
    local target = {}
    for k, v in pairs(t) do target[k] = v end
    setmetatable(target, meta)
    return target
end

-- converts a Domoticz date string to a Unix epoch
local function datetoepoch(datestring)
	local template = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
	local year, month, day, hour, minutes, seconds = datestring:match(template)
	return os.time{year=year, month=month, day=day, hour=hour, min=minutes, sec=seconds}
end

--[[
	**************************************************************************************************************************
	*                    THIS SECTION HOLDS ORIGINAL VERA BRIDGE FUNCTIONS INTERFACING WITH OPENLUUP                         *
	**************************************************************************************************************************
--]]

-- LUUP utility functions

local function getVar (name, service, device)
  service = service or SID.gateway
  device = device or devNo
  local x = luup.variable_get (service, name, device)
  return x
end

local function setVar (name, value, service, device)
  service = service or SID.gateway
  device = device or devNo
  local old = luup.variable_get (service, name, device)
  if tostring(value) ~= old then
   luup.variable_set (service, name, value, device)
  end
end

-- get and check UI variables
local function uiVar (name, default, lower, upper)
  local value = getVar (name)
  local oldvalue = value
  if value and (value ~= "") then           -- bounds check if required
    if lower and (tonumber (value) < lower) then value = lower end
    if upper and (tonumber (value) > upper) then value = upper end
  else
    value = default
  end
  value = tostring (value)
  if value ~= oldvalue then setVar (name, value) end   -- default or limits may have modified value
  return value
end

-- given a string of numbers s = "n, m, ..." convert to a set (for easy indexing)
local function convert_to_set (s)
  local set = {}
  for a in s: gmatch "%d+" do
    local n = tonumber (a)
    if n then set[n] = true end
  end
  return set
end

-----------
-- mapping between remote and local device IDs

local OFFSET                      -- offset to base of new device numbering scheme
local BLOCKSIZE = 10000           -- size of each block of device and scene IDs allocated
local Zwave = {}                  -- list of Zwave Controller IDs to map without device number translation

local function local_by_remote_id (id)
  return Zwave[id] or id + OFFSET
end

local function remote_by_local_id (id)
  return Zwave[id] or id - OFFSET
end

-- change parent of given device, and ensure that it handles child actions
local function set_parent (devNo, newParent)
  local dev = luup.devices[devNo]
  if dev then
    local meta = getmetatable(dev).__index
    luup.log ("device[" .. devNo .. "] parent set to " .. newParent)
    meta.handle_children = true                   -- handle Zwave actions
    dev.device_num_parent = newParent             -- parent resides in two places under different names !!
    dev.attributes.id_parent = newParent
  end
end

-- create bi-directional indices of rooms: room name <--> room number
local function index_rooms (rooms)
  local room_index = {}
  for number, name in pairs (rooms) do
    local roomNo = tonumber (number)      -- user_data may return string, not number
    room_index[roomNo] = name
    room_index[name] = roomNo
  end
  return room_index
end

-- make a list of our existing children, counting grand-children, etc.!!!
local function existing_children (parent)
  local c = {}
  local function children_of (d,index)
    for _, child in ipairs (index[d] or {}) do
      c[child] = luup.devices[child]
      children_of (child, index)
    end
  end

  local idx = {}
  for child, dev in pairs (luup.devices) do
    local num = dev.device_num_parent
    local children = idx[num] or {}
    children[#children+1] = child
    idx[num] = children
  end
  children_of (parent, idx)
  return c
end

-- create a new device, cloning the remote one
local function create_new (cloneId, dev, room)
--[[
          hidden          = nil,
          pluginnum       = d.plugin,
          disabled        = d.disabled,

--]]
  local d = chdev.create {
    devNo = cloneId,
    device_type = dev.device_type,
    internal_id = tostring(dev.altid or ''),
    invisible   = dev.invisible == "1",   -- might be invisible, eg. Zwave and Scene controllers
    json_file   = dev.device_json,
    description = dev.name,
    upnp_file   = dev.device_file,
    upnp_impl   = 'X',              -- override device file's implementation definition... musn't run here!
    parent      = devNo,
    password    = dev.password,
    room        = room,
    statevariables = dev.states,
    username    = dev.username,
    ip          = dev.ip,
    mac         = dev.mac,
  }
  luup.devices[cloneId] = d   -- remember to put into the devices table! (chdev.create doesn't do that)
end

-- ensure that all the parent/child relationships are correct
local function build_families (devices)
  for _, dev in pairs (devices) do   -- once again, this 'devices' table is from the 'user_data' request
    local cloneId  = local_by_remote_id (dev.id)
    local parentId = local_by_remote_id (tonumber (dev.id_parent) or 0)
    if parentId == OFFSET then parentId = devNo end      -- the bridge is the "device 0" surrogate
    local clone  = luup.devices[cloneId]
    local parent = luup.devices[parentId]
    if clone and parent then
      set_parent (cloneId, parentId)
    end
  end
end

-- return true if device is to be cloned
-- note: these are REMOTE devices from the Vera status request
-- consider: ZWaveOnly, Included, Excluded (...takes precedence over the first two)
-- and Mirrored, a sequence of "remote = local" device IDs for 'reverse bridging'

-- plus @explorer modification
-- see: http://forum.micasaverde.com/index.php/topic,37753.msg282098.html#msg282098

local function is_to_be_cloned (dev)
  local d = tonumber (dev.id)
  local p = tonumber (dev.id_parent)
  local zwave = p == 1 or d == 1
  if ZWaveOnly and p then -- see if it's a child of the remote zwave device
      local i = local_by_remote_id(p)
      if i and luup.devices[i] then zwave = true end
  end
  return  not (Excluded[d] or Mirrored[d])
          and (Included[d] or (not ZWaveOnly) or (ZWaveOnly and zwave) )
end

-- create the child devices managed by the bridge
local function create_children (devices, room)
  local N = 0
  local list = {}           -- list of created or deleted devices (for logging)
  local something_changed = false
  local current = existing_children (devNo)
  for _, dev in ipairs (devices) do   -- this 'devices' table is from the 'user_data' request
    dev.id = tonumber(dev.id)
    if is_to_be_cloned (dev) then
      N = N + 1
      local cloneId = local_by_remote_id (dev.id)
      if not current[cloneId] then
        something_changed = true
      else
        local old_room = luup.devices[cloneId].room_num
        room = (old_room ~= 0) and old_room or room   -- use room number
      end
      create_new (cloneId, dev, room) -- recreate the device anyway to set current attributes and variables
      list[#list+1] = cloneId
      current[cloneId] = nil
    end
  end
  if #list > 0 then luup.log ("creating device numbers: " .. json.encode(list)) end

  list = {}
  for n in pairs (current) do
    luup.devices[n] = nil       -- remove entirely!
    something_changed = true
    list[#list+1] = n
  end
  if #list > 0 then luup.log ("deleting device numbers: " .. json.encode(list)) end

  build_families (devices)
  if something_changed then luup.reload() end
  return N
end

--[[
	**************************************************************************************************************************
	*                          THIS SECTION HOLDS THE SPECIFIC FUNCTIONS TO DOMOTICZ BRIDGE                                  *
	**************************************************************************************************************************
--]]

-- FUNCTIONS TO EXTRACT DATA FROM DOMOTICZ AND CONVERT INTO A SYNTHETIC OPENLUUP USER_DATA CONTEXT

 -- deals with the messy device types that exist in Domoticz and put some consistency for device type lookup
local function devicetypeconvert(DZType, DZSubType, DZSwitchType)

	local function cleanstring(originalstring)
		originalstring = originalstring or ""
		return string.gsub(originalstring, "[% %/%c%+]", "") -- clean DZ device type from spaces, slashes and any control char
	end

	DZType = cleanstring(DZType or "")
	if string.match(DZType, "Switch") or string.match(DZType, "Light") then -- this is a switch or light and we need to look at SubType / SwitchType (Domoticz is messy there...)
		local DZSubType = cleanstring(DZSubType)
		if DZSubType == "Switch" or DZSubType == "AC" or DZSubType == "SelectorSwitch" then
			local 	DZSwitchType = cleanstring(DZSwitchType)
			if 		DZSwitchType == "MotionSensor" or
					DZSwitchType == "SmokeDetector" or
					DZSwitchType == "PushOnButton" or
					DZSwitchType == "Dimmer"
			then	DZType = DZSwitchType
			elseif
					string.match(DZSwitchType, "Blinds") then DZType = "Blinds"
			else
					DZType = "SwitchOnOff" -- default if no specific switch type
			end
		end
	end
	if not DZ2VeraMap[DZType] then DZType = "Generic" end -- no match with list of specific known "vera like" devices
	return DZType
end

-- generic call to Domoticz's API, used for polling and/or actions
local function DZAPI(APIcall, logmessage)
	APIcall = table.concat{"http://", ip, ":", DZport, APIcall}
	nicelog(APIcall)
	local result = ""
	local retdata, retcode = http.request(APIcall)
	if retcode == 200 then
		retdata, _ = json.decode(retdata)
		if retdata.status == "OK" then
			result = "API responded success"
			--luup.set_failure(0)
		else
			result = "API responded error !"
			--luup.set_failure(2) -- simulate authentication error to show device in red in the UI (NOT WORKING FOR NOW ???)
		end
	else
		result = "Network error, Domoticz API not reachable !"
		--luup.set_failure(2) -- simulate authentication error to show device in red in the UI (NOT WORKING FOR NOW ???)
	end
	nicelog({logmessage, " ", result})
	return retdata
end

-- this is the reading of Domoticz's API... used for building user_data and for subsequent variables polling
local function GetDZData(deviceidx)
	local DZData = {}
	local APIcall = ""

	if deviceidx then
		APIcall = "/json.htm?type=devices&rid=" .. tostring(deviceidx or "")
	else
		APIcall = "/json.htm?type=devices&filter=all&used=true&order=Name"
	end

	DZData = DZAPI(APIcall, "device(s) polling call to Domoticz:")

	return DZData.result, DZData.ActTime -- returns a table with the devices data and the timestamp of the data
end

-- dealing with the fact that Domoticz variables can have very different formats compared to openLuup
local function convertvariable(variable, value, format_table)
	local tempval = nil
	if not(variable == "BatteryLevel" and value == 255) then -- if BatteryLevel = 255 then it is not a battery device and we discard that variable
		tempval = tostring(value)
		if format_table.pattern then tempval = string.gsub(tempval, format_table.pattern, "") end
		if format_table.epoch then tempval = datetoepoch(tempval) end
		if format_table.boolean then if tempval == "Off" then tempval = "0" else tempval = "1" end end
		if variable == "LoadLevelStatus" and (tonumber(tempval) or 0) == 0 then tempval = "0" end -- deals with nil value sent for zero load by Domoticz
	end
	return tempval
end

-- add to each device as extracted from Domoticz the relevant "vera-like" attributes and variables
local function BuildDevice(device, context)

	local function BuildVariable(service, variable, value, id)
		local state = {}
		state.service = service or ""
		state.variable = variable or ""
		state.value = value or ""
		state.id = id
		return state
	end

	-- read the "Vera" device definition files to populate the default services/variables - thanks @akbooer !
	local function getdefaultvariables(services)
		local variables = {}
		local parameter = "%s,%s=%s"
		for _, service in pairs(services or {}) do
			if service.serviceId ~= "urn:micasaverde-com:serviceId:HaDevice1" then
				if service.SCPDURL then
					local svc = loader.read_service (service.SCPDURL)   -- read the service file(s)
					for _,v in ipairs (svc.variables or {}) do
						local default = v.defaultValue
						if default and default ~= '' then            -- only variables with defaults
							local index = table.concat{service.serviceId, ".", v.name}
							variables[index] = {service = service.serviceId, variable = v.name, value = default}
						end
					end
				end
			end
		end
		return variables
	end

	local DZType = devicetypeconvert(context.Type, context.SubType, context.SwitchType)
	nicelog({"Processing original device ", device.id, " ", device.name, " of type '", device.DZType, "' as '", DZType, "'"})

	-- process to add the "vera-like" serviceIds and variables
	device.device_file = DZ2VeraMap[DZType].device_file
	local loaderdevice = loader.read_device(device.device_file)
	device.device_type = loaderdevice.device_type
	device.device_json = loaderdevice.json_file
	device.states = {} -- the device variables

	-- initialize required device variables
	local defaultvariables = getdefaultvariables(loaderdevice.service_list)  -- use the openluup loader read_service function to initialize all default variables
	local state
	for _, state in pairs(DZ2VeraMap[DZType].states) do
		local tempval = convertvariable(state.variable, context[state.DZData], state)
		if tempval then
			table.insert(device.states, BuildVariable(state.service, state.variable, tempval, #device.states+1))
			local index = table.concat{state.service, ".", state.variable}
			if defaultvariables[index] then -- this is a default variable so we will mark as created
				defaultvariables[index]["created"] = true
			end
			-- register the variables to be managed by the polling loop
			local tmap = tablecopy(state) --{}
			tmap.idx = device.id
			table.insert(pollmap, tmap) -- pollmap is used in the polling loop to match Domoticz variables with openLuup's
		end
	end

	-- create the luup default variables not mapped by the bridge
	for _, variable in pairs(defaultvariables) do
		if not variable.created then
			table.insert(device.states, BuildVariable(variable.service, variable.variable, variable.value, #device.states+1))
		end
	end

	-- initialize actions to be handled for this device
	if DZ2VeraMap[DZType].actions then
		for _, action in pairs(DZ2VeraMap[DZType].actions) do
			local actiontable = tablecopy(action)
			actiontable.idx = device.id
			table.insert(actionmap, actiontable) -- actionmap is used to match Domoticz actions with openLuup actions
		end
	end

	return device
end

-- Create a "vera-like" userdata table from the Domoticz data
local function BuildUserData()
	local virtualuserdata = {}
	local k, v
	-- initialize userdata necessary fields - to be expanded
--	virtualuserdata.Mode = "1"
	virtualuserdata.BuildVersion = "*1.7.0*"
	virtualuserdata.model = "Domoticz"
	virtualuserdata.PK_AccessPoint = "88800000"
	virtualuserdata.devices = {}
	local DZData = GetDZData()
	for _, DZDev in pairs(DZData) do -- loop DZ devices
		device = {}
		device.id = DZDev.idx
		device.name = string.gsub(DZDev.Name, "[%_%-]", " ") -- DEV to allow better display in AltUI
		device.id_parent = 0 -- we assume all Domoticz devices to be level 1 children to the controller
		device.DZType = DZDev.Type -- the original Domoticz type
		device.DZSubType = DZDev.SubType -- the original Domoticz subtype
		device.DZSwitchType = DZDev.SwitchType or "" -- if this is a switch we need to capture this as well
		device=BuildDevice(device, DZDev)
		table.insert(virtualuserdata.devices, device) -- we are done with this device
	end
	return virtualuserdata
end

-- POLLING FUNCTIONS FOR VARIABLE UPDATES

-- handles some device specific triggers such as armed sensors
function updatevar(serviceId, variable, value, devNo)

	-- let's first update the required variable itself
	setVar (variable, value, serviceId, devNo)

	-- then go for possible associations...

	-- if security sensor trips while it is "Armed", then we need to raise the "ArmedTripped flag",
	-- but if it untrips, then we kill the "ArmedTripped" flag regarless of the "Armed" status
	-- we also update the "LastTrip" variable (and the now disregarded by MiOS "LastUnTrip" variable) as Domoticz only give last change timestamp
	if serviceId == "urn:micasaverde-com:serviceId:SecuritySensor1" and variable == "Tripped" then
		local ArmedTripped = "0"
		local Armed = luup.variable_get(serviceId, "Armed", devNo)
		if tonumber(value) == 1 then -- the sensor tripped
			setVar("LastTrip", os.time(), serviceId, devNo)
			if tonumber(Armed) == 1 then ArmedTripped = "1" end
		else
			setVar("LastUnTrip", os.time(), serviceId, devNo)
		end
		setVar("ArmedTripped", ArmedTripped, serviceId, devNo)
	end

	-- this requires some work to handle complex devices in the future

end

-- the function handling the polling requests, either for comprehensive or device specific polling
function polling(deviceidx)
	nicelog("Begin Domoticz polling !")
	local IndexedDZData = {}
	local tempval
	local DZData, timestamp = GetDZData(deviceidx)
	luup.variable_set(SID_DZB, "DataTimestamp", timestamp, devNo)
	for _, v in pairs(pollmap) do -- loop the table holding the devices/variables bridged
		for _, DZv in pairs(DZData) do -- for each device/variable in the table, do scan the DZ Data for matches
			if DZv.idx == v.idx then
				tempval = convertvariable(v.variable, DZv[v.DZData], v)
				if tempval then updatevar(v.service, v.variable, tempval, OFFSET + v.idx) end
				break -- avoid checking other devices once we have found a match
			end
		end
	end
	nicelog("Finished Domoticz polling !")
end

-- the polling loop !
function pollfullDZData()
	polling()
	luup.call_delay("pollfullDZData", POLL_DELAY)
end

-- HANDLER FOR BIDIRECTIONAL UPDATES

-- This is called by the companion script "script_device_openLuup.lua" to be installed in the appropriate ./domoticz/scripts/lua folder.
-- Each time a Domoticz device changes status, the below handler is called and prompts a ad-hoc polling of the relevant device if cloned in openLuup
function DZData_update(lul_request, lul_parameters, lul_outputformat)
	local err = true
	for key, value in pairs(lul_parameters) do
		if key == "idx" then
			for idx in value:gmatch "%d+" do -- loop each idx received in CSV string format... actually it seems that only one idx at a time is ever received ?
				nicelog({"Received change notification from Domoticz - Device = ", idx or ""}) 
				if tonumber(idx) ~= 0 then
					err = false
					polling(idx)
				end
			end
		end
	end
	if err then
		return "openLuup: Domoticz http request invalid: no device idx found !!!", "text/plain"
	else
		return "openLuup: Domoticz data change received OK", "text/plain"
	end
end

-- registers our handler as /data_request?id=lr_DZUpdate&idx=[x]
function sethandler()
	luup.register_handler("DZData_update", "DZUpdate")
end

-- ORIGINAL FUNCTION FROM VERABRIDGE MODIFIED

local function GetUserData ()
  local Domoticz
  local Ndev = 0
  local version
	Domoticz = BuildUserData() -- this is the trick for DZ Plugin... build & inject a virtual userdata build from Domoticz
  if Domoticz then
    luup.log "Domoticz info needed to build bridge environment received!"
    if Domoticz.devices then
      local new_room_name = "Domoticz"
      luup.log (new_room_name)
      rooms.create (new_room_name)

      remote_room_index = index_rooms (Domoticz.rooms or {})
      local_room_index  = index_rooms (luup.rooms or {})
      luup.log ("new room number: " .. (local_room_index[new_room_name] or '?'))

      version = Domoticz.BuildVersion
      luup.log ("BuildVersion = " .. version)

      Ndev = #Domoticz.devices
      luup.log ("number of remote devices = " .. Ndev)
      local roomNo = local_room_index[new_room_name] or 0
      Ndev = create_children (Domoticz.devices, roomNo)
    end
  end
  return Ndev, version
end

--
-- GENERIC ACTION HANDLER
--
-- called with serviceId and name of undefined action
-- returns action tag object with possible run/job/incoming/timeout functions
local function generic_action (serviceId, name)

	local function job (lul_device, lul_settings)
		local devNo = remote_by_local_id (lul_device)
		if not devNo then return end        -- not a device we have cloned
		local matchfound = false
		local message = "Action table match: %s - %s - %s"
		for _, action in pairs(actionmap) do
			if action.idx == tostring(devNo) and action.service == lul_settings.serviceId and action.action == lul_settings.action then
				matchfound = true
				nicelog(message:format(tostring(devNo), tostring(lul_settings.serviceId), tostring(lul_settings.action)))
				local APIcall = "/json.htm?type=command&param="
				local value = lul_settings[action.name]

				if action.boolean then
					local test = tonumber(value) > 0
					if action.inverted then test = not test end -- Domoticz treats blinds in inverted manner for commands (on = closed)
					if test then value = "On" else value = "Off" end
				end

				if action.self then -- this is an action for a local variable within the openLuup device
					luup.variable_set(action.service, action.command, value, OFFSET + tonumber(action.idx))
				else -- this is an action for Domoticz
					APIcall = table.concat{APIcall, string.format(action.command, devNo, value)}
					DZAPI(APIcall, "Action handler call to Domoticz:")
				end
				break -- we can stop here as we finished the action conversion
			end
		end

		if matchfound then
			return 4, 0
		else
			local message = "service/action not implemented: %d.%s.%s"
			nicelog(message: format (lul_device, lul_settings.serviceId, lul_settings.action))
			return 2, 0
		end
	end

	return {run = job}
end

--[[
	**************************************************************************************************************************
	*                    THIS SECTION HOLDS MOSTLY UNCHANGED ORIGINAL VERA BRIDGE FUNCTIONS                                  *
	**************************************************************************************************************************
--]]

-- update HouseMode variable and, possibly, the actual openLuup Mode
local function UpdateHouseMode (Mode)
  Mode = tostring(Mode)
  setVar ("HouseMode", Mode)                  -- 2016.05.15, thanks @logread!

  local current = userdata.attributes.Mode
  if current ~= Mode then
    if HouseModeMirror == '1' then
      luup.attr_set ("Mode", Mode)            -- 2016.05.23, thanks @konradwalsh!

    elseif HouseModeMirror == '2' then
      local now = os.time()
      luup.log "remote HouseMode differs from that set..."
      if now > HouseModeTime + 60 then        -- ensure a long delay between retries (Vera is slow to change)
        local switch = "remote HouseMode update, was: %s, switching to: %s"
        luup.log (switch: format (Mode, current))
        HouseModeTime = now
        local request = "http://%s:3480/data_request?id=action&serviceId=%s&DeviceNum=0&action=SetHouseMode&Mode=%s"
        luup.inet.wget (request: format(ip, SID.hag, current))
      end
    end
  end
end

-- find other bridges in order to establish base device number for cloned devices
local function findOffset ()
  local offset
  local my_type = luup.devices[devNo].device_type
  local bridges = {}      -- devNos of ALL bridges
  for d, dev in pairs (luup.devices) do
    if dev.device_type == my_type then
      bridges[#bridges + 1] = d
    end
  end
  table.sort (bridges)      -- sort into ascending order by deviceNo
  for d, n in ipairs (bridges) do
    if n == devNo then offset = d end
  end
  return offset * BLOCKSIZE   -- every remote machine starts in a new block of devices
end

-- logged request

local function wget (request)
  luup.log (request)
  local status, result = luup.inet.wget (request)
  if status ~= 0 then
    luup.log ("failed requests status: " .. (result or '?'))
  end
end

--
-- MIRRORS
--

-- openLuup.mirrors syntax is:
-- <VeraIP>
-- <VeraDeviceId> = <openLuupDeviceId>.<serviceId>.<variableName>
-- ...
--[==[

luup.attr_set ("openLuup.mirrors", [[
192.168.99.99
82 = 15.urn:upnp-org:serviceId:TemperatureSensor1.CurrentTemperature
83 = 16.urn:micasaverse-com:serviceId:HumiditySensor1.CurrentLevel
85 = 17.urn:cd-jackson-com:serviceId:SystemMonitor.memoryAvailable
85 = 17.urn:cd-jackson-com:serviceId:SystemMonitor.systemLuupRestartTime
]])

--]==]

-- set up variable watches for mirrored devices,
-- returning set of devices to ignore in cloning
-- and hash table for variable watch
local function set_of_mirrored_devices ()
  local Minfo = luup.attr_get "openLuup.mirrors"      -- this attribute set at startup
  local mirrored = {}
  local hashes = {}                     -- hash table of all mirrored variables
  local our_ip = false                  -- set to true when we're parsing our own data
  luup.log "reading mirror info..."
  for line in (Minfo or ''): gmatch "%C+" do
    local ip_info = line:match "^%s*(%d+%.%d+%.%d+%.%d+)"      -- IP address format
    if ip_info then
      our_ip = ip_info == ip
    elseif our_ip then
      local rem, lcl, srv, var  = line:match "^%s*(%d+)%s*=%s*(%d+)%.(%S+)%.(%S+)"
      if var then
        -- set up device watch
        rem = tonumber (rem)
        lcl = tonumber (lcl)
        luup.log (("mirror: rem=%s, lcl=%d.%s.%s"): format (rem, lcl, srv, var))
        local m = mirrored[rem] or {}                       -- flag remote device as a mirror, so don't clone locally
        local hash = table.concat ({lcl, srv, var}, '.')    -- build hash key
        hashes[hash] = rem
        m[#m+1] = {lcl=lcl, srv=srv, var=var, hash=hash}    -- add to list of watched vars for this device
        mirrored[rem] = m
      end
    end
  end
  return mirrored, hashes
end

-- Mirror watch callbacks

function VeraBridge_Mirror_Callback (dev, srv, var, _, new)
  local hash = table.concat ({dev, srv, var}, '.')
  local request = "http://%s:3480/data_request?id=variableset&DeviceNum=%d&serviceId=%s&Variable=%s&Value=%s"
  local rem = MirrorHash[hash]
  if rem then   --  send to remote device
    luup.inet.wget (request: format(ip, rem, srv, var, url.escape(new)))
  end
end

-- set up callbacks and initialise remote device variables
local function watch_mirror_variables (mirrored)
  for rem, mirror in pairs (mirrored) do
    for _, v in ipairs (mirror) do
      luup.variable_watch ("VeraBridge_Mirror_Callback", v.srv, v.var, v.lcl)   -- start watching
      local val = luup.variable_get (v.srv, v.var, v.lcl)
      VeraBridge_Mirror_Callback (rem, v.srv, v.var, nil, val or '')  -- use the callback to set the values
    end
  end
  return
end

--
-- Bridge ACTION handler(s)
--

-- copy all device files and icons from remote vera
-- (previously performed by the openLuup_getfiles utility)
function GetVeraFiles ()

  local code = [[

  local lfs = require "lfs"
  local f = io.open ("/www/directory.txt", 'w')
  for fname in lfs.dir ("%s") do
    if fname:match "lzo$" or fname: match "png$" then
      f:write (fname)
      f:write '\n'
    end
  end
  f:close ()

  ]]

  local function get_directory (path)
    local template = "http://%s:3480/data_request?id=action" ..
                      "&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1" ..
                      "&action=RunLua&Code=%s"
    local request = template:format (ip, url.escape (code: format(path)))

    local status, info = luup.inet.wget (request)
    if status ~= 0 then luup.log ("error creating remote directory listing: " .. status) return end

    status, info = luup.inet.wget ("http://" .. ip .. "/directory.txt")
    if status ~= 0 then luup.log ("error reading remote directory listing: " .. status) return end

    return info
  end

  local function get_files_from (path, dest, url_prefix)
    dest = dest or '.'
    url_prefix = url_prefix or ":3480/"
    luup.log ("getting files from " .. path)
    local info = get_directory (path)
    for x in info: gmatch "%C+" do
      local fname = x:gsub ("%.lzo",'')   -- remove unwanted extension for compressed files
      local status, content = luup.inet.wget ("http://" .. ip .. url_prefix .. fname)
      if status == 0 then
        luup.log (table.concat {#content, ' ', fname})

        local f = io.open (dest .. '/' .. fname, 'wb')
        f:write (content)
        f:close ()
      else
        luup.log ("error: " .. fname)
      end
    end
  end

  -- device, service, lua, json, files...
  lfs.mkdir "files"
  get_files_from ("/etc/cmh-ludl/", "files", ":3480/")
  get_files_from ("/etc/cmh-lu/", "files", ":3480/")
  luup.log "...end of device files"

  -- icons
  lfs.mkdir "icons"
  local _,b,_ = BuildVersion: match "(%d+)%.(%d+)%.(%d+)"    -- branch, major minor
  local major = tonumber(b)

  if major then
    if major > 5 then     -- UI7
      get_files_from ("/www/cmh/skins/default/img/devices/device_states/",
        "icons", "/cmh/skins/default/img/devices/device_states/")
    else                  -- UI5
      get_files_from ("/www/cmh/skins/default/icons/", "icons", "/cmh/skins/default/icons/")
    end
    luup.log "...end of icon files"
  end
end

--[[
	**************************************************************************************************************************
	*                                                      PLUGIN STARTUP                                                    *
	**************************************************************************************************************************
--]]

function init (lul_device)
  luup.log (ABOUT.NAME)
  luup.log (ABOUT.VERSION)

  devNo = lul_device
  ip = luup.attr_get ("ip", devNo)
  luup.log (ip)

  OFFSET = findOffset ()
  luup.log ("device clone numbering starts at " .. OFFSET)

  -- User configuration parameters: @explorer and @logread options

	DZport	= uiVar("DomoticzPort", DZport)	-- port on which the Domoticz server listens... default is 8084
--	ZWaveOnly = uiVar ("ZWaveOnly", '')         -- if set to true then only Z-Wave devices are considered by VeraBridge.
	Included  = uiVar ("IncludeDevices", '')    -- list of devices to include even if ZWaveOnly is set to true.
	Excluded  = uiVar ("ExcludeDevices", '')    -- list of devices to exclude from synchronization by VeraBridge,
												-- ...takes precedence over the first two.


  local hmm = uiVar ("HouseModeMirror",HouseModeOptions['0'])   -- 2016.05.23
  HouseModeMirror = hmm: match "^([012])" or '0'
  setVar ("HouseModeMirror", HouseModeOptions[HouseModeMirror]) -- replace with full string

  ZWaveOnly = false -- ZWaveOnly == "true"                         -- convert to logical
  Included = convert_to_set (Included)
  Excluded = convert_to_set (Excluded)
  Mirrored, MirrorHash = set_of_mirrored_devices ()       -- create set and hash of remote device IDs which are mirrored

  luup.devices[devNo].action_callback (generic_action)     -- catch all undefined action calls

  local Ndev
  Ndev, BuildVersion = GetUserData ()

  do -- version number
    --local y,m,d = ABOUT.VERSION:match "(%d+)%D+(%d+)%D+(%d+)"
    --local version = ("v%d.%d.%d"): format (y%2000,m,d)
    --setVar ("Version", version)
    setVar ("Version", ABOUT.VERSION)
  end

  setVar ("DisplayLine1", Ndev.." devices", SID.altui)
  setVar ("DisplayLine2", ip, SID.altui)

  if Ndev > 0 then
 --DEV TEMP   watch_mirror_variables (Mirrored)         -- set up variable watches for mirrored devices
	luup.call_delay("pollfullDZData", POLL_DELAY) -- deferred start for polling as we just read everything when creating user_data
	sethandler() -- register http handler for Domoticz openLuup script to call and notify of data changes
    luup.set_failure (0)                      -- all's well with the world
  else
    luup.set_failure (2)                      -- say it's an authentication error
  end
  return true, "OK", ABOUT.NAME
end

-----

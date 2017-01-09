--[[	Domoticz to openLuup notification of "devicechanged"
		Author : Logread
		Version: beta 2016-12-10
		Requires:
			1) Domoticz installed
      2) openLuup system running with DomoticzBridge plugin installed through the AltUI App Store
		Install instructions:
			1) Edit the openLuupIP variable in this script to change the IP address of the hardware running openLuup
			2) place this script in the [Domoticz path]/scripts/lua/ folder (e.g. /home/pi/domoticz/scripts/lua)
		Description:
			provides asynchronous notifications to openLuup of changes in Domoticz devices status/values
			by sending an HTTP GET request to a handler in openLuup's DomoticzBridge plugin.
			Since the value collected by this script from Domoticz's "devicechanged" table is not useable 'per se'
			by openLuup's DomoticzBridge, only the CSV list of devices changed will be sent to DomoticzBridge.
			The latter will respond by sending to Domoticz a device specific poll for each device changed...
			This involves more network traffic than desirable, but since most likely Domoticz and openLuup will
			reside on the same LAN/Subnet if not the same physical hardware, this should not impact performance or
			responsiveness of either openLuup or Domoticz.
--]]

commandArray = {}

local idxlist = {}
-- url to notify the DomoticzBridge plugin on the openLuup system of a device change 
local handlerurl = "http://%s:3480/data_request?id=lr_DZUpdate&idx=%s" -- DO NOT CHANGE !!!

-- read configuration from the Domoticz uservariables if they exist
local openLuupIP = uservariables["openLuupIP"] or "127.0.0.1"
local openLuupNoNotify = uservariables["openLuupNoNotify"] or ""

local function is_in_csv_list(csvstring, value)
  value = tostring(value) or ""
  csvstring = csvstring or ""
  local isthere = false
  for svalue in csvstring:gmatch("%d+") do
    if tonumber(svalue) == tonumber(value) then
      isthere = true
      break
    end
  end
  return isthere
end

for name, _ in pairs(devicechanged) do
	local idx = otherdevices_idx[name] -- convert the device name to its index
	if idx and not(is_in_csv_list(openLuupNoNotify, idx)) then
		table.insert(idxlist, idx) 	-- build a table of all devices changed
	end
end
if next(idxlist) then
  local csvstring = table.concat(idxlist, ",") or "" -- make the table of devices a comma separated string for the http call
  local cmd = string.format(handlerurl, openLuupIP, csvstring)
  print(cmd) -- log for debug
  commandArray["OpenURL"] = cmd
-- else
--  print("Device change ignored as per 'openLuupNoNotify' uservariable") -- log for debug
end

return commandArray

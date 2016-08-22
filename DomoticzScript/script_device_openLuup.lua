--[[	Domoticz to openLuup notification of "devicechanged"
		Author : Logread
		Version: Alpha 2016-08-13
		Requires:
			1) Domoticz installed
			 2) openLuup installed, with DomoticzBridge plugin installed
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
			NOTE: To simplify installation, code has been written to rely on Domoticz's built-in http call (avoiding
			the need for external lua modules), but this means there is no error checking... any errors will need
			to be tracked from openLuup's log file (/etc/cmh-ludl/LuaUPnP.log)
--]]

commandArray = {}

local openLuupIP = "127.0.0.1" -- assumes openLuup running on same machine as Domoticz
-- To Do : get IP from a Domoticz "user variable"

local url = "http://%s:3480/data_request?id=lr_DZUpdate&idx=%s" -- DO NOT CHANGE !!!
local idxlist = {}
for name, _ in pairs(devicechanged) do
	local idx = otherdevices_idx[name] -- convert the device name to its index
	if idx then
		table.insert(idxlist, idx) 	-- build a table of all devices changed
	end
end
local csvstring = table.concat(idxlist, ",") or "" -- make the table of devices a comma separated string for the http call
local cmd = string.format(url, openLuupIP, csvstring)
print(cmd) -- log for debug
commandArray["OpenURL"] = cmd

return commandArray

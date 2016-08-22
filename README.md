# DomoticzBridge
Domoticz Bridge plug-in for openLuup

IMPORTANT: This is Alpha software... in early testing stages and any use is at your own risk !!! This is software for the technically savy at this stage and not supported except by my goodwill...

What this is: a way to drive a Domoticz home automation setup from an openLuup environment

Rationale: I wrote this plugin after testing a new HA setup for my main home based on a Rapsberry Pi / Aeotec Z-Wave GEN5 stick / Domoticz, instead of the MiOS/Vera system I have had running at my vacation home.
I found Domoticz to be an excellent HA platform but I like the Luup environment running on Vera system much better from a scripting perspective as well as from its huge list of plugins. I therefore wrote this plugin to get the best of the two platforms :)

For more info on openLuup see http://forum.micasaverde.com/index.php/board,79.0.html

For more info on Domoticz see www.domoticz.com

What this does:
- clone devices from a Domoticz installation to an openLuup environment
- mirrors Domoticz device variables/status as openLuup devices
- performs certain actions (from the UI or from scenes/plugins, etc...) within openLuup that are mirrored on the Domoticz

What this does not do:
- given the complexity of matching Domoticz devices and actions with openLuup's, only device types and actions that have been programmed will work within openLuup...
Contact me if you have a device type that is not supported and I will see if I can implement it

Installation:

a) on the openLuup system:
- from the AltAppStore on a running openLuup system, install the plugin
- in the openLuup UI, edit the newly created plugin device: "control panel" / "device attributes" and set the IP to the system running Domoticz (if same system than openLuup, best is to use a localhost address such as 127.0.0.1)
- perform a Luup reload

b) on the Domoticz system:
- copy the "script_device_openLuup.lua" from https://github.com/999LV/DomoticzBridge/tree/master/DomoticzScript to the scripts folder of your Domoticz installation (e.g. /home/pi/domoticz/scripts/lua/ on a standard Raspberry Pi install), using your favorite file utility, e.g. WinSCP

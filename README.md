# CPX-2025-Maestro-The-New-Frontier-Infrastructure-as-a-Code

This code allows you to create your own EXL or Maestro group. 
The system assumes similarly powerful devices, and VSNext used.

Each VS has 2 interfaces for data, and 1 for management. 

In this example, the data network VLANs are simply rotated.

You must edit the Combined_vars.txt file to suit your own environment. 

A Maestro MHO must be accessible (and any other MHO's connected) - as well as the Maestro Infra. in place.  
What changes - is how we build and configure.

For EXL, the Appliances must be connected as per documentation, with Sync network connected. One of the devices must have an IP/mask/gw, so, for example, via console setup like this:
```console
set interface Mgmt ipv4-address <Mgmt_IP> mask-length <CIDR_Mask>
set static-route default nexthop gateway address 192.168.1.254 off
set static-route default nexthop gateway address <System_DG>> on
```
For an EXL system, you run:
```console
./01_CPX_EXL_create.sh
./02_CPX_EXL_Mgmt_vs0.sh CPX_EXL_VSN '172.31.100.114/22' vpn123
./03_CPX_EXL_VSN.sh
./04_CPX_EXL_Mgmt_VSN.sh
```
This will:
* Will build the group and run FTW.  Enabled EXL and VSN Modes.
* Adds the created system in the Mgmt. With the name, IP, and SIC key defined.
* Adds bond, vlans, vswitches, and some extra VS. Tested to more than 100VS.
* Bring all the created VS from 03 script, into the Mgmt, sets trust, policy and more, then installs a simple policy.

Many of the definitions for EXL are in the Combined_vars.txt file.

For Maestro system, you run:
```console
./01_CPX_SG_create.sh 1 1 'eth1-Mgmt1' 2 'eth1-49 eth2-49' CPX_Sec_Group '192.168.14.10/24' '192.168.14.1' '192.168.05.23'
./02_CPX_SG_Mgmt_vs0.sh CPX_Sec_Group '192.168.14.10/24' vpn123
./03_CPX_SG_VSN.sh  
./04_CPX_SG_Mgmt_VSN.sh 
./05_CPX_SG_extend.sh 3 1 '192.168.05.23'
./06_CPX_Addlic.sh 
```
This will (on SG):
* Build a group with 1 Gateway, 1 Mgmt interface (eth1-Mgmt1, 2 data interfaces, (eth1-49 eth2-49) call the system CPX-SG1, set the SG IP mask as 172.31.100.182/22 with Def GW 172.31.100.1 and connect to MHO 172.31.100.180 to make the changes.
* Adds the created system in the the Mgmt. With the name, IP, and SIC key defined.
* Adds bond, vlans, vswitches, and some extra VS. Tested to more than 100VS
* Bring all the created VS from 03 script, into the Mgmt, sets trust, policy and more, then installs a simple policy
* If you built with only 1 gateway - as in the example above, you may want to add more gateways, once you know the system works for you. This will extend the group 1 by 3 gateays on the MHO 192.168.05.23
* Add licenses for lab use (production systems will license automatically)

If you want to reset, then on EXL, you login to the group, and use the normal set fcd revert R<VERSION>
For Maestro, you can run 
```console
./CPX_SG_delete.sh <Group Number> '<MHO_IP>' 
```
**All code is provided for lab use.  Make sure you are happy with with it does, and you know what you are doing, before using it anywhere else!**

TK

# CPX-2025-Maestro-The-New-Frontier-Infrastructure-as-a-Code

This code allows you to create your own EXL or Maestro gruop. 
The system assumes similarly powerful devices, and VSNext used.

Each VS has 2 interfaces for data, and 1 for management. 

In this example, the data network VLANs are simply rotated.

You must edit the Combined_vars.txt file to suit your own environment. 

A Maestro MHO must be accessable (and any other MHO's connected) - as well as the Maestro Infra. in place.  
What changes - is how we build and configure.

For EXL, the Appliances must be connected as per documentation, with Sync network connected. One of the devices must have an IP/mask/gw, so, for example, via console setup like this:

set interface Mgmt ipv4-address <Mgmt_IP> mask-length <CIDR_Mask>
set static-route default nexthop gateway address 192.168.1.254 off
set static-route default nexthop gateway address <System_DG>> on

For an EXL system, you run:
./01_CPX_EXL_create.sh [Will build the gruop and run FTW.  Enabled EXL and VSN Modes.]
./02_CPX_EXL_Mgmt_vs0.sh CPX_EXL_VSN '172.31.100.114/22' vpn123  [Adds the created system in the the Mgmt. With the name, IP, and SIC key defined.]
./03_CPX_EXL_VSN.sh [Adds bond, vlans, vswitches, and some extra VS. Tested to more than 100VS.]
./04_CPX_EXL_Mgmt_VSN.sh [Bring all the created VS from 03 script, into the Mgmt, sets trust, policy and more, then installs a simple policy.]

Many of the definitions for EXL are in the Combined_vars.txt file.

For Maestro system, you run:
./01_CPX_SG_create.sh 1 1 'eth1-Mgmt1' 2 'eth1-49 eth2-49' CPX-SG1 '172.31.100.182/22' '172.31.100.1' '172.31.100.180'
./02_CPX_SG_Mgmt_vs0.sh CPX-SG-VSN '172.31.100.182/22' vpn123  [Adds the created system in the the Mgmt. With the name, IP, and SIC key defined.]
./03_CPX_SG_VSN.sh [Adds bond, vlans, vswitches, and some extra VS. Tested to more than 100VS]
./04_CPX_SG_Mgmt_VSN.sh [Bring all the created VS from 03 script, into the Mgmt, sets trust, policy and more, then installs a simple policy]
./05_CPX_SG_extend.sh [If you built with only 1 gateway - as in the example above, you may want to add more gateways, once you know the system works for you]
./06_CPX_Addlic.sh [To add licenses for lab use (production systems will license automatically)]

If you want to reset, then on EXL, you login to the group, and use the normal set fcd revert R<VERSION>
For Maestro, you can run ./CPX_delete.sh <Group Number> '<MHO_IP>' 

All code is provided for lab use.  Make sure you are happy with with it does, and you know what you are doing, before using it anywhere else!

TK
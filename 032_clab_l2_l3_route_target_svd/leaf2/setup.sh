#!/bin/bash

# VTEP IP
ip addr add 100.64.0.2/32 dev lo

# Leaf - spine leg
ip addr add 192.168.1.3/24 dev eth1

# host_l3_2
ip addr add 192.170.10.1/24 dev eth4

# single bridge with a single a single vxlan device 
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 addrgenmode none
ip link set br0 address aa:bb:cc:00:00:65
ip link add vxlan0 type vxlan dstport 4789 local 100.64.0.2 nolearning external vnifilter
ip link set vxlan0 addrgenmode none master br0
ip link set vxlan0 address aa:bb:cc:00:00:65
ip link set br0 up
ip link set vxlan0 up
# configure vxlan to map vni <-> vid
bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off

# IP-VRF vrf100 vni 100 vid 10 table 1100
# map vni 100 to vid 10 and create its bridge port
bridge vlan add dev br0 vid 10 self
bridge vlan add dev vxlan0 vid 10
bridge vni add dev vxlan0 vni 100 # add vni if using vnifilter
bridge vlan add dev vxlan0 vid 10 tunnel_info id 100 # map vlan to vni
ip link add vlan10 link br0 type vlan id 10 # create vlan on top of bridge
ip link set vlan10 address aa:bb:cc:00:00:65 addrgenmode none # set L3VNI devices to routermac and no address
# create vrf and attach bridge port and host link
ip link add vrf100 type vrf table 1100
ip link set eth4 master vrf100
ip link set vlan10 master vrf100
ip link set vlan10 up
ip link set vrf100 up

# MAC-VRF LAN1 vni 110 vid 11 
bridge vlan add dev br0 vid 11 self
bridge vlan add dev vxlan0 vid 11
bridge vni add dev vxlan0 vni 110
bridge vlan add dev vxlan0 vid 11 tunnel_info id 110
ip link add vlan11 link br0 type vlan id 11
ip link set vlan11 addr aa:bb:cc:00:01:65 # unique MAC per L2VNI+VTEP combo (or use anycast MAC, see below)
ip addr add 192.168.10.1/24 dev vlan11 # shared gateway IP per L2VNI, on all VTEPs
ip link set vlan11 master vrf100
ip link set eth2 master br0
bridge vlan add dev eth2 vid 11 pvid untagged
ip link set vlan11 up

# MAC-VRF LAN2 vni 120 vid 12 
bridge vlan add dev br0 vid 12 self
bridge vlan add dev vxlan0 vid 12
bridge vni add dev vxlan0 vni 120
bridge vlan add dev vxlan0 vid 12 tunnel_info id 120
ip link add vlan12 link br0 type vlan id 12
ip link set vlan12 addr aa:bb:cc:00:02:65 # unique MAC per L2VNI+VTEP combo (or use anycast MAC, see below)
ip addr add 192.168.11.1/24 dev vlan12 # shared gateway IP per L2VNI, on all VTEPs
ip link set vlan12 master vrf100
ip link set eth3 master br0
bridge vlan add dev eth3 vid 12 pvid untagged
ip link set vlan12 up

#!/bin/bash

# vtep
ip addr add 100.64.0.2/32 dev lo
# spine
ip addr add 192.168.1.3/24 dev eth1
# host2
ip addr add 192.168.12.1/24 dev eth2
# host4
ip addr add 192.168.14.1/24 dev eth3

# single bridge with a single vxlan device
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

# L3 VRF red/100
# map vni 100 to vid 10 and create its bridge port
bridge vlan add dev br0 vid 10 self
bridge vlan add dev vxlan0 vid 10
bridge vni add dev vxlan0 vni 100 # add vni if using vnifilter
bridge vlan add dev vxlan0 vid 10 tunnel_info id 100 # map vlan to vni
ip link add redbr link br0 type vlan id 10 # create vlan on top of bridge
ip link set redbr address aa:bb:cc:00:00:65 addrgenmode none # set L3VNI devices to routermac and no address
# create vrf and attch bridge port and host link
ip link add red type vrf table 1100
ip link set eth2 master red
ip link set redbr master red
ip link set redbr up
ip link set red up

# L3 VRF blue/101
# map vni 101 to vid 11 and create its bridge port
bridge vlan add dev br0 vid 11 self
bridge vlan add dev vxlan0 vid 11
bridge vni add dev vxlan0 vni 101 # add vni if using vnifilter
bridge vlan add dev vxlan0 vid 11 tunnel_info id 101 # map vlan to vni
ip link add bluebr link br0 type vlan id 11 # create vlan on top of bridge
ip link set bluebr address aa:bb:cc:00:00:65 addrgenmode none # set L3VNI devices to routermac and no address
# create vrf and attach bridge port and host link
ip link add blue type vrf table 1101
ip link set eth3 master blue
ip link set bluebr master blue
ip link set bluebr up
ip link set blue up

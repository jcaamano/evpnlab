#!/bin/bash

# vtep
ip addr add 100.64.0.2/32 dev lo
# spine
ip addr add 192.168.1.3/24 dev eth1
# host2
ip addr add 192.168.12.1/24 dev eth2
# host4
ip addr add 192.168.14.1/24 dev eth3

# L3 VRF red/100
ip link add red type vrf table 1100
ip link set eth2 master red
ip link add br100 type bridge
ip link set br100 master red addrgenmode none
ip link set br100 addr aa:bb:cc:00:00:65
ip link add vni100 type vxlan local 100.64.0.2 dstport 4789 id 100 nolearning
ip link set vni100 master br100 addrgenmode none
ip link set vni100 type bridge_slave neigh_suppress on learning off
ip link set vni100 up
ip link set br100 up
ip link set red up

# L3 VRF blue/101
ip link add blue type vrf table 1101
ip link set eth3 master blue
ip link add br101 type bridge
ip link set br101 master blue addrgenmode none
ip link set br101 addr aa:bb:cc:00:00:65
ip link add vni101 type vxlan local 100.64.0.2 dstport 4789 id 101 nolearning
ip link set vni101 master br101 addrgenmode none
ip link set vni101 type bridge_slave neigh_suppress on learning off
ip link set vni101 up
ip link set br101 up
ip link set blue up

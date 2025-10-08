#!/bin/bash
#

ip addr add 192.168.12.2/24 dev eth1

ip r del default
ip r add default via 192.168.12.1
sleep INF

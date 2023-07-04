#!/usr/bin/bash

# This add the internal IP to the external `br-ex` bridge used by OVS:
internal_ip="192.168.127.10/24"
nmcli connection modify br-ex +ipv4.addresses "${internal_ip}" ipv4.method auto
ip addr add "${internal_ip}" dev br-ex
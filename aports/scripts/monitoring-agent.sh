# monitoring-agent.sh - sourced by every genapkovl-<profile>.sh
#
# Makes the VM discoverable and monitorable by the zabbix, prometheus and
# grafana profiles:
#
# - A second NIC (eth1), when there is one, joins the "monitoring network":
#   all VMs started with
#       -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1
#   share one virtual LAN that stays on the host. eth1 gets a random MAC
#   (QEMU gives every VM the same default one) and an IPv4 link-local
#   address (169.254.0.0/16, busybox zcip), so no DHCP server is needed. The
#   same works on a bridged LAN.
# - avahi announces the VM on eth1 as a "_qemu-recipes._tcp" service. Its TXT
#   records name the profile and the ports of the agents (and of Prometheus,
#   Zabbix or Grafana on the monitoring VMs).
# - node_exporter (Prometheus) listens on :9100, zabbix_agent2 on :10050 for
#   passive checks from 127.0.0.1 and the link-local network.
#
# Without eth1 nothing is announced and the agents are only reachable from
# inside the VM.
#
# Needs $tmp, makefile and rc_add from the calling script. The packages in
# MONITORING_AGENT_APKS must also be listed in the profile's mkimg file.

# shellcheck shell=sh disable=SC2154 # $tmp is set by the calling genapkovl-*.sh

MONITORING_AGENT_APKS="avahi avahi-openrc dbus dbus-openrc
prometheus-node-exporter prometheus-node-exporter-openrc
zabbix-agent2 zabbix-agent2-openrc"

# monitoring_agent <profile> [<key>=<value>...]: extra TXT records
monitoring_agent() {
	local profile="$1" txt
	shift

	for txt in $MONITORING_AGENT_APKS; do
		echo "$txt" >> "$tmp"/etc/apk/world
	done

	# --- eth1 on the monitoring network ------------------------------------
	mkdir -p "$tmp"/etc/init.d "$tmp"/usr/share/qemu-recipes
	makefile root:root 0755 "$tmp"/etc/init.d/monitoring-net <<-'EOF'
	#!/sbin/openrc-run

	description="Join the monitoring network on eth1 (IPv4 link-local)"

	pidfile=/run/monitoring-net.pid

	depend() {
		need localmount
		after networking
		before avahi-daemon
	}

	start() {
		local mac
		if [ ! -e /sys/class/net/eth1 ]; then
			einfo "No second NIC (eth1), not joining the monitoring network"
			return 0
		fi
		# QEMU hands out the same default MACs (52:54:00:12:34:5x) in
		# every VM, which breaks a LAN shared by several of them.
		mac=$(cat /sys/class/net/eth1/address)
		case $mac in
		52:54:00:12:34:5?)
			mac="52:54:00$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':')"
			ip link set eth1 down
			ip link set eth1 address "$mac"
			;;
		esac
		ip link set eth1 up
		ebegin "Joining the monitoring network on eth1 ($mac)"
		start-stop-daemon --start --background --make-pidfile \
			--pidfile "$pidfile" --exec /sbin/zcip \
			-- -f eth1 /usr/share/qemu-recipes/zcip.script
		eend $?
	}

	stop() {
		[ -f "$pidfile" ] || return 0
		ebegin "Leaving the monitoring network"
		start-stop-daemon --stop --pidfile "$pidfile"
		ip addr flush dev eth1 2>/dev/null
		eend 0
	}
	EOF

	makefile root:root 0755 "$tmp"/usr/share/qemu-recipes/zcip.script <<-'EOF'
	#!/bin/sh
	# Called by zcip with $interface and $ip set.
	case "$1" in
	init) ip link set "$interface" up ;;
	config) ip addr add "$ip"/16 broadcast 169.254.255.255 dev "$interface" ;;
	deconfig) ip addr flush dev "$interface" ;;
	esac
	exit 0
	EOF

	# --- avahi: announce this VM on eth1 -------------------------------------
	mkdir -p "$tmp"/etc/avahi/services
	makefile root:root 0644 "$tmp"/etc/avahi/avahi-daemon.conf <<-'EOF'
	[server]
	use-ipv4=yes
	use-ipv6=no
	allow-interfaces=eth1
	enable-dbus=yes
	ratelimit-interval-usec=1000000
	ratelimit-burst=1000

	[wide-area]
	enable-wide-area=no

	[publish]
	publish-hinfo=no
	publish-workstation=no
	publish-aaaa-on-ipv4=no

	[reflector]

	[rlimits]
	EOF

	{
		cat <<-EOF
		<?xml version="1.0" standalone='no'?>
		<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
		<!-- A VM from qemu-recipes, see /usr/share/qemu-recipes -->
		<service-group>
		  <name replace-wildcards="yes">%h</name>
		  <service>
		    <type>_qemu-recipes._tcp</type>
		    <port>9100</port>
		    <txt-record>profile=$profile</txt-record>
		    <txt-record>node_exporter=9100</txt-record>
		    <txt-record>zabbix_agent=10050</txt-record>
		EOF
		for txt in "$@"; do
			printf '    <txt-record>%s</txt-record>\n' "$txt"
		done
		cat <<-EOF
		  </service>
		</service-group>
		EOF
	} | makefile root:root 0644 "$tmp"/etc/avahi/services/qemu-recipes.service

	# --- agents ----------------------------------------------------------------
	mkdir -p "$tmp"/etc/conf.d "$tmp"/etc/zabbix
	makefile root:root 0644 "$tmp"/etc/conf.d/node-exporter <<-'EOF'
	ARGS="--web.listen-address=:9100"
	EOF

	# Replaces the packaged file: zabbix refuses parameters set twice, so
	# Server can't be changed with an include.
	makefile root:root 0644 "$tmp"/etc/zabbix/zabbix_agent2.conf <<-'EOF'
	# zabbix_agent2 for qemu-recipes VMs: passive checks only, from this VM
	# and from the monitoring network (IPv4 link-local).
	LogFile=/var/log/zabbix/zabbix_agent2.log
	LogFileSize=1
	Server=127.0.0.1,169.254.0.0/16
	ServerActive=
	HostnameItem=system.hostname
	PluginSocket=/run/zabbix/agent.plugin.sock
	ControlSocket=/run/zabbix/zabbix_agent2.sock
	Include=./zabbix_agent2.d/plugins.d/*.conf
	EOF

	for txt in dbus monitoring-net avahi-daemon node-exporter zabbix-agent2; do
		rc_add "$txt" default
	done
}

# monitoring_peers_tool: install /usr/local/bin/qemu-recipes-peers, which
# lists the VMs on the monitoring network (needs avahi-tools), one per line:
#   <name> <ipv4> <key>=<value>...      (TXT records: profile=..., ports)
# <name> is the VM's mDNS host name, made unique by avahi ("lamp", "lamp-2").
monitoring_peers_tool() {
	echo avahi-tools >> "$tmp"/etc/apk/world
	mkdir -p "$tmp"/usr/local/bin
	makefile root:root 0755 "$tmp"/usr/local/bin/qemu-recipes-peers <<-'EOF'
	#!/bin/sh
	# qemu-recipes-peers - list the qemu-recipes VMs on the monitoring network
	avahi-browse --resolve --parsable --terminate --no-db-lookup \
		_qemu-recipes._tcp 2>/dev/null \
	| awk -F';' '$1 == "=" && $3 == "IPv4" {
		name = $7; sub(/\.local$/, "", name)
		txt = $10; gsub(/"/, "", txt)
		print name, $8, txt
	}' | sort -u
	EOF
}

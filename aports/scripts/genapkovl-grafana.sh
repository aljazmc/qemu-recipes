#!/bin/sh -e
# genapkovl-grafana.sh - build the boot overlay (apkovl) for the "grafana" profile
# Installed by mkimg.grafana.sh via apkovl
#
# The resulting VM boots straight into Grafana (with the Zabbix plugin) and
# adds every prometheus and zabbix VM from this repository it finds on the
# monitoring network (see monitoring-agent.sh) as a data source:
# "Prometheus on <vm>" and "Zabbix on <vm>". VMs that come up later are added
# within ~10s, and a data source follows its VM when the VM's address
# changes. Nothing has to be installed or configured inside the guest.
#
# Start QEMU with e.g.:
#
#   mkdir -p ~/grafana-dev
#   qemu-img create -f qcow2 ~/grafana-data.qcow2 2G   # optional, keeps the data
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-grafana-v3.24-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::3000-:3000,hostfwd=tcp::2222-:22 \
#       -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
#       -virtfs local,path="$HOME/grafana-dev",mount_tag=grafana,security_model=none,id=grafana \
#       -drive file="$HOME/grafana-data.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:3000 (admin / admin).
#
# - The shared directory (/srv/grafana) holds dashboards/*.json (folder
#   "Shared", re-read every 10s, so dashboards edited on the host show up
#   right away).
# - The dashboards "VMs (Prometheus)" and "VMs (Zabbix)" (folder
#   qemu-recipes) let you pick any discovered data source.
# - Data sources stay when their VM goes away, so a VM that is only down for
#   a while keeps its history and dashboards.
# - A blank virtio disk is formatted (ext4, label "grafanadb") on first boot
#   and holds the Grafana data from then on. Without it the data lives in RAM
#   and is lost on poweroff.
#
# Build-time settings (environment variables):
#   GRAFANA_ADMIN_USER             Grafana admin login                [admin]
#   GRAFANA_ADMIN_PASSWORD         Grafana admin password             [admin]
#   ZABBIX_USER                    user for discovered Zabbix VMs     [Admin]
#   ZABBIX_PASSWORD                its password                       [zabbix]
#   GRAFANA_ZABBIX_PLUGIN_VERSION  Grafana Zabbix plugin to bundle    [latest]

HOSTNAME="${1:-grafana}"

: "${ZABBIX_USER:=Admin}"
: "${ZABBIX_PASSWORD:=zabbix}"

cleanup() { rm -rf "$tmp"; }
tmp="$(mktemp -d)"
trap cleanup EXIT

makefile() {
	# makefile <owner> <perms> <file>  (content from stdin)
	cat > "$3"
	chown "$1" "$3"
	chmod "$2" "$3"
}

rc_add() {
	# rc_add <service> <runlevel>
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

# Agents and the monitoring network, shared by all profiles
. "$(dirname "$0")"/monitoring-agent.sh
. "$(dirname "$0")"/monitoring-grafana.sh

mkdir -p "$tmp"/etc
makefile root:root 0644 "$tmp"/etc/hostname <<EOF
$HOSTNAME
EOF

mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# --- Packages installed from the boot media at every boot --------------------
mkdir -p "$tmp"/etc/apk
makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
alpine-base
blkid
e2fsprogs
openssh
openssh-server-common-openrc
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/grafana.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the grafana-* services -------------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/grafana-dev <<EOF
# Settings for /etc/init.d/grafana-prep and grafana-discover

SHARE="/srv/grafana"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=grafana)
SHARE_TAG="grafana"
# filesystem label of the persistent data disk
DATA_LABEL="grafanadb"

# Grafana API (to reload the data sources)
GRAFANA_ADMIN_USER="$GRAFANA_ADMIN_USER"
GRAFANA_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# credentials for the Zabbix API of discovered zabbix VMs
ZABBIX_USER="$ZABBIX_USER"
ZABBIX_PASSWORD="$ZABBIX_PASSWORD"

# one file per discovered data source, kept with the Grafana data
DATASOURCES="/var/lib/grafana/qemu-recipes-datasources"
EOF

# --- Grafana with the Zabbix plugin ---------------------------------------------------
grafana_setup /srv/grafana/dashboards
grafana_zabbix_plugin

# --- Service: mount share, prepare data storage ------------------------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/grafana-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared directory and prepare Grafana storage"

depend() {
	need localmount
	after modules
	before grafana
}

. /etc/conf.d/grafana-dev

mount_share() {
	mountpoint -q "$SHARE" && return 0
	mkdir -p "$SHARE"
	ebegin "Mounting host share '$SHARE_TAG' on $SHARE"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$SHARE" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, $SHARE is kept in RAM"
	fi
}

# Use a virtio disk labelled $DATA_LABEL for the data, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_storage() {
	local dev= d= n=

	dev=$(blkid -L "$DATA_LABEL" 2>/dev/null) || dev=
	if [ -z "$dev" ]; then
		for d in /dev/vd?; do
			[ -b "$d" ] || continue
			n=${d#/dev/}
			ls -d /sys/block/"$n"/"$n"?* >/dev/null 2>&1 && continue
			[ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] && continue
			[ -n "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null)" ] && continue
			ebegin "Formatting blank disk $d for Grafana data"
			mkfs.ext4 -q -L "$DATA_LABEL" "$d"
			eend $? || return 1
			dev=$d
			break
		done
	fi

	mkdir -p /var/lib/grafana
	if [ -n "$dev" ] && ! mountpoint -q /var/lib/grafana; then
		ebegin "Mounting $dev as Grafana storage"
		mount -t ext4 "$dev" /var/lib/grafana
		eend $?
	elif [ -z "$dev" ]; then
		ewarn "No persistent disk, Grafana data is kept in RAM"
	fi
	mkdir -p /var/lib/grafana/data "$DATASOURCES"
	chown -R grafana:grafana /var/lib/grafana
}

start() {
	mount_share
	prepare_storage || return 1
	mkdir -p "$SHARE"/dashboards
	# data sources found on earlier boots
	/usr/local/bin/grafana-discover --write-only
}
EOF

# --- Service: add the monitoring VMs as data sources --------------------------
makefile root:root 0755 "$tmp"/etc/init.d/grafana-discover <<'EOF'
#!/sbin/openrc-run

description="Add the prometheus/zabbix VMs on the monitoring network to Grafana"

supervisor=supervise-daemon
command=/usr/local/bin/grafana-discover
output_log=/var/log/grafana-discover.log
error_log=/var/log/grafana-discover.log
respawn_delay=5
respawn_max=0

depend() {
	need grafana-prep avahi-daemon
	after grafana
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/grafana-discover <<'EOF'
#!/bin/sh
# grafana-discover - every 10s, write a data source for each prometheus and
# zabbix VM on the monitoring network into $DATASOURCES, combine them into
# Grafana's provisioning and reload it when something changed.
#   --write-only  only combine what is in $DATASOURCES (used at boot)

. /etc/conf.d/grafana-dev

PROVISIONED=/etc/grafana/provisioning/datasources/discovered.yaml

# fragment <uid> <name> <type> <url> [zabbix]
fragment() {
	cat <<-YAML
	  - name: $2
	    uid: $1
	    type: $3
	    access: proxy
	    url: $4
	YAML
	[ "$5" = zabbix ] || return 0
	cat <<-YAML
	    jsonData:
	      username: $ZABBIX_USER
	      trends: true
	      trendsFrom: 7d
	      trendsRange: 4d
	      timeout: 30
	    secureJsonData:
	      password: $ZABBIX_PASSWORD
	YAML
}

discover() {
	qemu-recipes-peers | while read -r name ip txt; do
		uid=$(echo "$name" | tr -c 'a-zA-Z0-9\n' _)
		for kv in $txt; do
			case $kv in
			prometheus=*)
				fragment "prometheus-$uid" "Prometheus on $name" prometheus \
					"http://$ip:${kv#*=}" > "$DATASOURCES/prometheus-$uid.yaml.new"
				;;
			zabbix_api=*)
				fragment "zabbix-$uid" "Zabbix on $name" alexanderzobnin-zabbix-datasource \
					"http://$ip:${kv#*=}/api_jsonrpc.php" zabbix > "$DATASOURCES/zabbix-$uid.yaml.new"
				;;
			*) continue ;;
			esac
			for new in "$DATASOURCES"/*.yaml.new; do
				if cmp -s "$new" "${new%.new}"; then
					rm -f "$new"
				else
					mv "$new" "${new%.new}"
					echo "grafana-discover: data source ${new##*/} for $name ($ip)"
				fi
			done
		done
	done
}

# combine the fragments, true if the provisioning file changed
combine() {
	{
		echo 'apiVersion: 1'
		echo 'datasources:'
		cat "$DATASOURCES"/*.yaml 2>/dev/null
	} > "$PROVISIONED.new"
	if cmp -s "$PROVISIONED.new" "$PROVISIONED"; then
		rm -f "$PROVISIONED.new"
		return 1
	fi
	chmod 0640 "$PROVISIONED.new"
	chgrp grafana "$PROVISIONED.new"
	mv "$PROVISIONED.new" "$PROVISIONED"
}

reload() {
	wget -q -O /dev/null --post-data= \
		--header "Authorization: Basic $(printf '%s:%s' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD" | base64 | tr -d '\n')" \
		http://127.0.0.1:3000/api/admin/provisioning/datasources/reload
}

mkdir -p "$DATASOURCES"
if [ "$1" = --write-only ]; then
	combine
	exit 0
fi

pending=
while :; do
	discover
	combine && pending=yes
	if [ -n "$pending" ]; then
		reload && pending= && echo "grafana-discover: data sources reloaded"
	fi
	sleep 10
done
EOF

# --- Monitoring agents (see monitoring-agent.sh) ---------------------------
monitoring_agent grafana grafana=3000
monitoring_peers_tool

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd grafana-prep grafana-discover; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

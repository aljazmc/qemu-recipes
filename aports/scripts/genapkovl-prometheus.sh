#!/bin/sh -e
# genapkovl-prometheus.sh - build the boot overlay (apkovl) for the "prometheus" profile
# Installed by mkimg.prometheus.sh via apkovl
#
# The resulting VM boots straight into Prometheus and Grafana, and monitors
# every VM from this repository it finds on the monitoring network (see
# monitoring-agent.sh): their node_exporter is scraped as job "node", with
# the labels instance (VM name) and profile. VMs that come up later are
# picked up within ~10s. Nothing has to be installed or configured inside the
# guest.
#
# Start QEMU with e.g.:
#
#   mkdir -p ~/prometheus-dev
#   qemu-img create -f qcow2 ~/prometheus-data.qcow2 4G   # optional, keeps the data
#   qemu-system-x86_64 -enable-kvm -m 1024 -smp 2 \
#       -cdrom iso/alpine-v3.24-prometheus-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::3000-:3000,hostfwd=tcp::9090-:9090,hostfwd=tcp::2222-:22 \
#       -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
#       -virtfs local,path="$HOME/prometheus-dev",mount_tag=prometheus,security_model=none,id=prometheus \
#       -drive file="$HOME/prometheus-data.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:3000 (Grafana) or http://localhost:9090 (Prometheus).
#
# - The shared directory (/srv/prometheus) holds:
#     rules/*.yml       alerting and recording rules
#     scrape/*.yml      extra scrape configs (files with scrape_configs:)
#     dashboards/*.json Grafana dashboards (folder "Shared")
#   Changes are picked up within ~10s (Prometheus is reloaded). An empty
#   directory gets these folders and an example rule.
# - Grafana has Prometheus as its default data source and the dashboard
#   "VMs (Prometheus)" (folder qemu-recipes).
# - A blank virtio disk is formatted (ext4, label "promdb") on first boot and
#   holds the Prometheus and Grafana data from then on. Without it they live
#   in RAM and are lost on poweroff.
#
# Build-time settings (environment variables):
#   GRAFANA_ADMIN_USER      Grafana admin login             [admin]
#   GRAFANA_ADMIN_PASSWORD  Grafana admin password          [admin]
#   PROMETHEUS_RETENTION    how long samples are kept       [15d]
#   SCRAPE_INTERVAL         scrape and rule interval        [15s]

HOSTNAME="${1:-prometheus}"

: "${PROMETHEUS_RETENTION:=15d}"
: "${SCRAPE_INTERVAL:=15s}"

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
prometheus
prometheus-openrc
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/prometheus.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the prometheus-* services ----------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0644 "$tmp"/etc/conf.d/prometheus-dev <<EOF
# Settings for /etc/init.d/prometheus-prep and prometheus-discover

SHARE="/srv/prometheus"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=prometheus)
SHARE_TAG="prometheus"
# filesystem label of the persistent data disk
DATA_LABEL="promdb"
# file_sd file with the discovered VMs
TARGETS="/var/lib/qemu-recipes/node.json"
EOF

makefile root:root 0644 "$tmp"/etc/conf.d/prometheus <<EOF
prometheus_config_file=/etc/prometheus/prometheus.yml
prometheus_storage_path=/var/lib/prometheus/data
prometheus_retention_time=$PROMETHEUS_RETENTION
prometheus_args="--web.enable-lifecycle"

output_log=/var/log/prometheus.log
error_log=/var/log/prometheus.log
EOF

# --- Prometheus ------------------------------------------------------------------
mkdir -p "$tmp"/etc/prometheus
makefile root:root 0644 "$tmp"/etc/prometheus/prometheus.yml <<EOF
# Prometheus for qemu-recipes: the VMs on the monitoring network are found
# by /etc/init.d/prometheus-discover and written to
# /var/lib/qemu-recipes/node.json. Add your own rules and scrape configs in
# the shared directory instead of here.
global:
  scrape_interval: $SCRAPE_INTERVAL
  evaluation_interval: $SCRAPE_INTERVAL

rule_files:
  - /srv/prometheus/rules/*.yml

scrape_config_files:
  - /srv/prometheus/scrape/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
        labels:
          instance: $HOSTNAME
  - job_name: grafana
    static_configs:
      - targets: ['localhost:3000']
        labels:
          instance: $HOSTNAME
  - job_name: node
    file_sd_configs:
      - files: ['/var/lib/qemu-recipes/node.json']
        refresh_interval: 30s
EOF

# --- Grafana -----------------------------------------------------------------------
grafana_setup /srv/prometheus/dashboards
makefile root:root 0644 "$tmp"/etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: 15s
EOF

# --- Service: mount share, prepare data storage, populate share --------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/prometheus-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared directory and prepare Prometheus/Grafana storage"

depend() {
	need localmount
	after modules
	before prometheus grafana
}

. /etc/conf.d/prometheus-dev

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
	local dev= d= n= data=/var/lib/monitoring-data

	dev=$(blkid -L "$DATA_LABEL" 2>/dev/null) || dev=
	if [ -z "$dev" ]; then
		for d in /dev/vd?; do
			[ -b "$d" ] || continue
			n=${d#/dev/}
			ls -d /sys/block/"$n"/"$n"?* >/dev/null 2>&1 && continue
			[ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] && continue
			[ -n "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null)" ] && continue
			ebegin "Formatting blank disk $d for Prometheus and Grafana data"
			mkfs.ext4 -q -L "$DATA_LABEL" "$d"
			eend $? || return 1
			dev=$d
			break
		done
	fi

	mkdir -p /var/lib/prometheus /var/lib/grafana
	if [ -n "$dev" ] && ! mountpoint -q /var/lib/prometheus; then
		ebegin "Mounting $dev as Prometheus and Grafana storage"
		mkdir -p "$data"
		mount -t ext4 "$dev" "$data" \
			&& mkdir -p "$data"/prometheus "$data"/grafana \
			&& mount --bind "$data"/prometheus /var/lib/prometheus \
			&& mount --bind "$data"/grafana /var/lib/grafana
		eend $?
	elif [ -z "$dev" ]; then
		ewarn "No persistent disk, Prometheus and Grafana data are kept in RAM"
	fi
	mkdir -p /var/lib/prometheus/data /var/lib/grafana/data
	chown -R prometheus:prometheus /var/lib/prometheus
	chown -R grafana:grafana /var/lib/grafana
}

populate_share() {
	mkdir -p "$SHARE"/rules "$SHARE"/scrape "$SHARE"/dashboards
	[ -n "$(ls -A "$SHARE"/rules)" ] && return 0
	cat > "$SHARE"/rules/example.yml <<-'YAML'
	# Example rules, loaded by Prometheus from the shared directory.
	# Edit or add *.yml files here: Prometheus reloads them within ~10s.
	groups:
	  - name: qemu-recipes
	    rules:
	      - alert: VMDown
	        expr: up{job="node"} == 0
	        for: 1m
	        labels:
	          severity: warning
	        annotations:
	          summary: "VM {{ $labels.instance }} ({{ $labels.profile }}) is down"
	YAML
}

start() {
	mount_share
	prepare_storage || return 1
	populate_share
	mkdir -p "$(dirname "$TARGETS")"
	[ -f "$TARGETS" ] || echo '[]' > "$TARGETS"
}
EOF

# --- Service: discover the VMs on the monitoring network ---------------------
makefile root:root 0755 "$tmp"/etc/init.d/prometheus-discover <<'EOF'
#!/sbin/openrc-run

description="Scrape the qemu-recipes VMs found on the monitoring network"

supervisor=supervise-daemon
command=/usr/local/bin/prometheus-discover
output_log=/var/log/prometheus-discover.log
error_log=/var/log/prometheus-discover.log
respawn_delay=5
respawn_max=0

depend() {
	need prometheus-prep avahi-daemon
	after prometheus
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/prometheus-discover <<'EOF'
#!/bin/sh
# prometheus-discover - keep $TARGETS (file_sd) in line with the VMs on the
# monitoring network, and reload Prometheus when the rules or scrape configs
# in the shared directory change.

. /etc/conf.d/prometheus-dev

# this VM itself, over loopback (it is skipped in the peer list)
self_target() {
	printf '  {"targets": ["127.0.0.1:9100"], "labels": {"instance": "%s", "profile": "prometheus"}}' \
		"$(hostname)"
}

targets() {
	local own
	own=" $(ip -4 -o addr show | awk '{ split($4, a, "/"); printf "%s ", a[1] }')"
	echo '['
	self_target
	qemu-recipes-peers | while read -r name ip txt; do
		case $own in *" $ip "*) continue ;; esac
		port= profile=
		for kv in $txt; do
			case $kv in
			node_exporter=*) port=${kv#*=} ;;
			profile=*) profile=${kv#*=} ;;
			esac
		done
		[ -n "$port" ] || continue
		printf ',\n  {"targets": ["%s:%s"], "labels": {"instance": "%s", "profile": "%s"}}' \
			"$ip" "$port" "$name" "$profile"
	done
	printf '\n]\n'
}

config_sum() {
	cat "$SHARE"/rules/*.yml "$SHARE"/scrape/*.yml 2>/dev/null | md5sum
}

last_config=$(config_sum)
while :; do
	targets > "$TARGETS.new"
	if ! cmp -s "$TARGETS.new" "$TARGETS"; then
		echo "prometheus-discover: targets now:"
		grep -o '"instance": "[^"]*"' "$TARGETS.new" | cut -d'"' -f4 | tr '\n' ' '
		echo
		mv "$TARGETS.new" "$TARGETS"
	else
		rm -f "$TARGETS.new"
	fi

	config=$(config_sum)
	if [ "$config" != "$last_config" ]; then
		last_config=$config
		echo "prometheus-discover: shared rules or scrape configs changed, reloading"
		wget -q -O /dev/null --post-data= http://127.0.0.1:9090/-/reload \
			|| echo "prometheus-discover: reload failed, see /var/log/prometheus.log"
	fi
	sleep 10
done
EOF

# --- Monitoring agents (see monitoring-agent.sh) ---------------------------
monitoring_agent prometheus prometheus=9090 grafana=3000
monitoring_peers_tool

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd prometheus-prep prometheus prometheus-discover; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

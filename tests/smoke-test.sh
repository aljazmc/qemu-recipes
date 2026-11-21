#!/usr/bin/env bash
#
# Smoke test for the built ISO images.
#
# Boots each image headless in QEMU with an empty shared directory and a blank
# database disk, like a first boot on a developer machine, and checks that:
#
#   - the VM boots to a login prompt (serial console),
#   - sshd and node_exporter answer,
#   - the profile's stack serves what it should (and its database works),
#   - files created in the shared directory belong to the host user.
#
# Every VM is on a monitoring network of its own for the test (a multicast
# group other than the default one). The monitoring profiles get companion
# VMs on it and must discover and monitor them:
#
#   prometheus, zabbix   a node VM
#   grafana              a prometheus and a zabbix VM
#
# Usage:
#   tests/smoke-test.sh                 test every ISO found in iso/
#   tests/smoke-test.sh lamp node       test only these profiles
#
# Environment:
#   SMOKE_TIMEOUT    seconds to wait for each check   [300, 900 without KVM]
#   SMOKE_PORT_BASE  first host port used (5 ports)   [18080]
#   SMOKE_MCAST      monitoring network of the test   [230.0.0.1:<port base + 1000>]
#   SMOKE_KEEP       yes = keep the work directory even on success [no]
#
# Exit status is 0 only if every tested profile passes. On failure the work
# directory (serial logs, shared directory, fetched pages) is kept for a look.

set -u

cd "$(dirname "$0")/.." || exit 1

PROFILES="django drupal grafana joomla lamp laravel node prometheus wordpress x11 zabbix"
PORT_BASE=${SMOKE_PORT_BASE:-18080}
HTTP_PORT=$PORT_BASE
SSH_PORT=$((PORT_BASE + 1))
VNC_PORT=$((PORT_BASE + 2))
EXTRA_PORT=$((PORT_BASE + 3))
EXPORTER_PORT=$((PORT_BASE + 4))
MCAST=${SMOKE_MCAST:-230.0.0.1:$((PORT_BASE + 1000))}

if [ -w /dev/kvm ]; then
	ACCEL="-enable-kvm"
	TIMEOUT=${SMOKE_TIMEOUT:-300}
else
	echo "warning: /dev/kvm is not writable, running without KVM (slow)" >&2
	ACCEL=""
	TIMEOUT=${SMOKE_TIMEOUT:-900}
fi

command -v qemu-system-x86_64 > /dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
command -v qemu-img > /dev/null || { echo "qemu-img not found" >&2; exit 1; }
command -v curl > /dev/null || { echo "curl not found" >&2; exit 1; }

QEMU_PID=""
COMPANION_PIDS=""
WORK=""

cleanup() {
	local pid n
	for pid in $QEMU_PID $COMPANION_PIDS; do
		kill "$pid" 2> /dev/null || continue
		# started from a subshell, so not our child: wait by polling
		n=0
		while kill -0 "$pid" 2> /dev/null && [ $n -lt 50 ]; do
			sleep 0.2
			n=$((n + 1))
		done
	done
	QEMU_PID=""
	COMPANION_PIDS=""
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

log() { printf '    %s\n' "$*"; }

# port_free PORT: nothing listens on 127.0.0.1:PORT
port_free() {
	! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null
}

# wait_for DESCRIPTION COMMAND...: retry COMMAND until it succeeds or TIMEOUT
wait_for() {
	local what=$1 start=$SECONDS
	shift
	while ! "$@"; do
		if ! kill -0 "$QEMU_PID" 2> /dev/null; then
			log "FAIL $what (QEMU exited)"
			return 1
		fi
		if [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
			log "FAIL $what (timeout after ${TIMEOUT}s)"
			return 1
		fi
		sleep 3
	done
	log "ok   $what ($((SECONDS - start))s)"
}

# --- Profiles ------------------------------------------------------------------

iso_of() {
	ls iso/alpine-"$1"-*-x86_64.iso 2> /dev/null | sort -V | tail -n 1
}

mem_of() {
	case $1 in
		laravel) echo 1024 ;;
		zabbix) echo 3072 ;;
		*) echo 2048 ;;
	esac
}

# share_tag_of PROFILE: the -virtfs mount_tag the profile mounts
share_tag_of() {
	case $1 in
		drupal|grafana|joomla|prometheus|wordpress|zabbix) echo "$1" ;;
		x11) echo home ;;
		*) echo www ;;
	esac
}

# guest_ports_of PROFILE: guest ports behind HTTP_PORT and EXTRA_PORT
guest_ports_of() {
	case $1 in
		django) echo 8000 ;;
		grafana) echo 3000 ;;
		node) echo 3000 ;;
		prometheus) echo 3000 9090 ;;
		x11) echo 6080 ;;
		zabbix) echo 80 3000 ;;
		*) echo 80 ;;
	esac
}

companions_of() {
	case $1 in
		prometheus|zabbix) echo node ;;
		grafana) echo prometheus zabbix ;;
	esac
}

# start_vm PROFILE DIR [HOSTFWD]: boot PROFILE with its files in DIR (serial
# log, share, disk) on the test's monitoring network; prints QEMU's pid
start_vm() {
	local profile=$1 dir=$2 fwd=${3:-} tag disk=()
	tag=$(share_tag_of "$profile")
	mkdir -p "$dir/share"
	if [ "$profile" != x11 ]; then
		qemu-img create -q -f qcow2 "$dir/disk.qcow2" 8G || return 1
		disk=(-drive file="$dir/disk.qcow2",if=virtio,format=qcow2)
	fi
	# shellcheck disable=SC2086
	qemu-system-x86_64 $ACCEL -m "$(mem_of "$profile")" -smp 2 -cdrom "$(iso_of "$profile")" \
		-display none -serial file:"$dir/serial.log" -monitor none \
		-nic user,model=virtio-net-pci${fwd:+,$fwd} \
		-nic socket,model=virtio-net-pci,mcast="$MCAST",localaddr=127.0.0.1 \
		-virtfs local,path="$dir/share",mount_tag="$tag",security_model=none,id="$tag" \
		"${disk[@]}" > "$dir/qemu.log" 2>&1 &
	echo $!
}

# --- Checks ------------------------------------------------------------------

booted() {
	grep -aq 'login:' "$1/serial.log" 2> /dev/null
}

# banner PORT PREFIX: the first line sent on PORT starts with PREFIX
banner() {
	local line
	line=$(
		exec 3<> "/dev/tcp/127.0.0.1/$1" || exit 1
		timeout 5 head -n 1 <&3
	) 2> /dev/null
	case $line in "$2"*) return 0 ;; esac
	return 1
}

# page PORT PATH PATTERN [CURL ARGS...]: GET returns 200 and the body
# matches PATTERN (ERE)
page() {
	local port=$1 path=$2 pattern=$3 out code
	shift 3
	out="$WORK/page$(echo "$path" | tr -c 'a-zA-Z0-9\n' _ | cut -c1-80).html"
	code=$(curl -s -o "$out" -w '%{http_code}' --max-time 10 "$@" \
		"http://127.0.0.1:$port$path") || return 1
	[ "$code" = 200 ] && grep -Eq "$pattern" "$out"
}

# grafana PORT PATH PATTERN: like page, as Grafana's admin
grafana() {
	page "$1" "$2" "$3" -u admin:admin
}

# django_login PORT USER PASSWORD: the Django admin login works (needs the
# database and the admin user)
django_login() {
	local jar="$WORK/cookies" token code
	rm -f "$jar"
	token=$(curl -s -c "$jar" --max-time 10 "http://127.0.0.1:$1/admin/login/" \
		| sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p') || return 1
	[ -n "$token" ] || return 1
	code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -b "$jar" --max-time 10 \
		-H "Referer: http://127.0.0.1:$1/admin/login/" \
		--data-urlencode "csrfmiddlewaretoken=$token" \
		--data-urlencode "username=$2" --data-urlencode "password=$3" \
		"http://127.0.0.1:$1/admin/login/?next=/admin/") || return 1
	[ "$code" = "302 http://127.0.0.1:$1/admin/" ]
}

# zabbix_agent_up PORT HOST: Zabbix has HOST, and its agent is available
zabbix_agent_up() {
	local api="http://127.0.0.1:$1/api_jsonrpc.php" token out
	token=$(curl -s --max-time 10 -H 'Content-Type: application/json-rpc' -d \
		'{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
		"$api" | sed -n 's/.*"result":"\([0-9a-f]*\)".*/\1/p')
	[ -n "$token" ] || return 1
	out=$(curl -s --max-time 10 -H 'Content-Type: application/json-rpc' \
		-H "Authorization: Bearer $token" -d \
		"{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$2\"]},\"output\":[\"host\"],\"selectInterfaces\":[\"ip\",\"available\"]},\"id\":2}" \
		"$api")
	curl -s --max-time 10 -o /dev/null -H 'Content-Type: application/json-rpc' \
		-H "Authorization: Bearer $token" \
		-d '{"jsonrpc":"2.0","method":"user.logout","params":[],"id":3}' "$api"
	echo "$out" > "$WORK/zabbix-host-$2.json"
	echo "$out" | grep -q '"available":"1"'
}

# share_owned: the shared directory is not empty and everything in it
# belongs to the host user
share_owned() {
	[ -n "$(ls -A "$WORK/share")" ] || return 1
	[ -z "$(find "$WORK/share" ! -user "$(id -u)" -print -quit)" ]
}

# --- One profile -------------------------------------------------------------

test_profile() {
	local profile=$1 companion ports guest_http guest_extra fwd ok=0 dir pid

	for companion in "$profile" $(companions_of "$profile"); do
		if [ -z "$(iso_of "$companion")" ]; then
			log "FAIL no $companion ISO in iso/ (build it first, see README)"
			return 1
		fi
	done
	log "image $(iso_of "$profile")"

	for port in "$HTTP_PORT" "$SSH_PORT" "$VNC_PORT" "$EXTRA_PORT" "$EXPORTER_PORT"; do
		if ! port_free "$port"; then
			log "FAIL host port $port is in use (set SMOKE_PORT_BASE)"
			return 1
		fi
	done

	WORK=$(mktemp -d "${TMPDIR:-/tmp}/qemu-recipes-smoke-$profile.XXXXXX")

	# companions first, so they are there to be discovered
	for companion in $(companions_of "$profile"); do
		dir="$WORK/companion-$companion"
		pid=$(start_vm "$companion" "$dir") || return 1
		COMPANION_PIDS="$COMPANION_PIDS $pid"
		log "companion $companion started"
	done

	ports=$(guest_ports_of "$profile")
	guest_http=${ports%% *}
	guest_extra=${ports#* }
	fwd="hostfwd=tcp:127.0.0.1:$HTTP_PORT-:$guest_http,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
	fwd="$fwd,hostfwd=tcp:127.0.0.1:$EXPORTER_PORT-:9100"
	[ "$guest_extra" != "$ports" ] && fwd="$fwd,hostfwd=tcp:127.0.0.1:$EXTRA_PORT-:$guest_extra"
	[ "$profile" = x11 ] && fwd="$fwd,hostfwd=tcp:127.0.0.1:$VNC_PORT-:5900"

	QEMU_PID=$(start_vm "$profile" "$WORK" "$fwd") || return 1

	wait_for "boots to a login prompt" booted "$WORK" || ok=1
	[ $ok = 0 ] && { wait_for "sshd answers" banner "$SSH_PORT" SSH-2.0- || ok=1; }
	[ $ok = 0 ] && { wait_for "node_exporter answers" \
		page "$EXPORTER_PORT" /metrics '^node_uname_info' || ok=1; }

	if [ $ok = 0 ]; then
		case $profile in
		django)
			wait_for "runserver serves the new project" \
				page "$HTTP_PORT" / 'The install worked successfully' || ok=1
			wait_for "admin login works (PostgreSQL, admin user)" \
				django_login "$HTTP_PORT" admin admin || ok=1
			;;
		drupal)
			wait_for "Drupal front page renders (database works)" \
				page "$HTTP_PORT" / '<title>[^<]*Drupal Dev' || ok=1
			wait_for "Drupal login page (clean URLs)" \
				page "$HTTP_PORT" /user/login 'id="edit-name"' || ok=1
			;;
		grafana)
			wait_for "Grafana is up" page "$HTTP_PORT" /api/health '"database": *"ok"' || ok=1
			wait_for "the prometheus VM is a working data source" \
				grafana "$HTTP_PORT" /api/datasources/uid/prometheus-prometheus/health '"status": *"OK"' || ok=1
			wait_for "the zabbix VM is a working data source" \
				grafana "$HTTP_PORT" /api/datasources/uid/zabbix-zabbix/health '"status": *"OK"' || ok=1
			wait_for "the dashboards are provisioned" \
				grafana "$HTTP_PORT" '/api/search?tag=qemu-recipes' 'VMs \(Zabbix\)' || ok=1
			;;
		joomla)
			wait_for "Joomla front page renders (database works)" \
				page "$HTTP_PORT" / 'Joomla Dev' || ok=1
			wait_for "Joomla administrator login page" \
				page "$HTTP_PORT" /administrator/ 'mod-login-username' || ok=1
			;;
		lamp)
			wait_for "Apache + PHP serve the starter page, MariaDB connected" \
				page "$HTTP_PORT" / 'connected, server [0-9.]+-MariaDB' || ok=1
			;;
		laravel)
			# A Laravel project needs internet on first boot; offline the
			# starter page is served instead. Either one proves the stack.
			wait_for "lighttpd + PHP-FPM serve Laravel (or the starter page)" \
				page "$HTTP_PORT" / '<title>Laravel|connected, server [0-9.]+-MariaDB' || ok=1
			;;
		node)
			wait_for "Node app answers, PostgreSQL connected" \
				page "$HTTP_PORT" / 'connected, PostgreSQL [0-9]' || ok=1
			;;
		prometheus)
			wait_for "Prometheus scrapes the node VM it discovered" \
				page "$EXTRA_PORT" '/api/v1/query?query=up%7Bjob%3D%22node%22%2Cprofile%3D%22node%22%7D' \
				'"value":\[[0-9.]+,"1"\]' || ok=1
			wait_for "the rules from the shared directory are loaded" \
				page "$EXTRA_PORT" /api/v1/rules '"name":"VMDown"' || ok=1
			wait_for "Grafana's Prometheus data source works" \
				grafana "$HTTP_PORT" /api/datasources/uid/prometheus/health '"status": *"OK"' || ok=1
			wait_for "the dashboards are provisioned" \
				grafana "$HTTP_PORT" '/api/search?tag=qemu-recipes' 'VMs \(Prometheus\)' || ok=1
			;;
		wordpress)
			wait_for "WordPress front page renders (database works)" \
				page "$HTTP_PORT" / 'wp-content' || ok=1
			wait_for "WordPress login page" \
				page "$HTTP_PORT" /wp-login.php 'user_login' || ok=1
			;;
		x11)
			wait_for "VNC server answers" banner "$VNC_PORT" 'RFB ' || ok=1
			wait_for "noVNC is served" \
				page "$HTTP_PORT" /vnc.html 'noVNC' || ok=1
			;;
		zabbix)
			wait_for "Zabbix frontend login page" \
				page "$HTTP_PORT" / '<title>[^<]*Zabbix' || ok=1
			wait_for "Zabbix monitors the node VM it discovered (agent available)" \
				zabbix_agent_up "$HTTP_PORT" node || ok=1
			wait_for "Grafana's Zabbix data source works" \
				grafana "$EXTRA_PORT" /api/datasources/uid/zabbix/health '"status": *"OK"' || ok=1
			;;
		esac
	fi

	if [ $ok = 0 ] && [ "$profile" != x11 ]; then
		wait_for "shared directory is populated and owned by the host user" \
			share_owned || ok=1
	fi

	cleanup

	if [ $ok = 0 ] && [ "${SMOKE_KEEP:-no}" != yes ]; then
		rm -rf "$WORK"
	else
		log "work directory kept: $WORK"
	fi
	return $ok
}

# --- Main --------------------------------------------------------------------

if [ $# -gt 0 ]; then
	selected="$*"
else
	selected=""
	for profile in $PROFILES; do
		[ -n "$(iso_of "$profile")" ] && selected="$selected $profile"
	done
	if [ -z "$selected" ]; then
		echo "no ISO images in iso/, build one first (./project.sh start)" >&2
		exit 1
	fi
fi

passed=""
failed=""
for profile in $selected; do
	case " $PROFILES " in
		*" $profile "*) ;;
		*) echo "unknown profile '$profile' (one of: $PROFILES)" >&2; exit 2 ;;
	esac
	echo "==> $profile"
	if test_profile "$profile"; then
		passed="$passed $profile"
	else
		failed="$failed $profile"
	fi
done

echo
[ -n "$passed" ] && echo "passed:$passed"
[ -n "$failed" ] && { echo "FAILED:$failed"; exit 1; }
exit 0

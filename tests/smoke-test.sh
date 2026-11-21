#!/usr/bin/env bash
#
# Smoke test for the built ISO images.
#
# Boots each image headless in QEMU with an empty shared directory and a blank
# database disk, like a first boot on a developer machine, and checks that:
#
#   - the VM boots to a login prompt (serial console),
#   - sshd answers,
#   - the profile's stack serves what it should (and its database works),
#   - files created in the shared directory belong to the host user.
#
# Usage:
#   tests/smoke-test.sh                 test every ISO found in iso/
#   tests/smoke-test.sh lamp node       test only these profiles
#
# Environment:
#   SMOKE_TIMEOUT    seconds to wait for each check   [300, 900 without KVM]
#   SMOKE_PORT_BASE  first host port used             [18080]
#   SMOKE_KEEP       yes = keep the work directory even on success [no]
#
# Exit status is 0 only if every tested profile passes. On failure the work
# directory (serial log, shared directory, fetched pages) is kept for a look.

set -u

cd "$(dirname "$0")/.." || exit 1

PROFILES="lamp laravel node wordpress x11"
PORT_BASE=${SMOKE_PORT_BASE:-18080}
HTTP_PORT=$PORT_BASE
SSH_PORT=$((PORT_BASE + 1))
VNC_PORT=$((PORT_BASE + 2))

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
WORK=""

cleanup() {
	if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2> /dev/null; then
		kill "$QEMU_PID" 2> /dev/null
		wait "$QEMU_PID" 2> /dev/null
	fi
	QEMU_PID=""
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

# --- Checks ------------------------------------------------------------------

booted() {
	grep -aq 'login:' "$WORK/serial.log" 2> /dev/null
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

# page PORT PATH PATTERN: GET returns 200 and the body matches PATTERN (ERE)
page() {
	local out="$WORK/page$(echo "$2" | tr -c 'a-zA-Z0-9\n' _).html" code
	code=$(curl -s -o "$out" -w '%{http_code}' --max-time 10 \
		"http://127.0.0.1:$1$2") || return 1
	[ "$code" = 200 ] && grep -Eq "$3" "$out"
}

# share_owned: the shared directory is not empty and everything in it
# belongs to the host user
share_owned() {
	[ -n "$(ls -A "$WORK/share")" ] || return 1
	[ -z "$(find "$WORK/share" ! -user "$(id -u)" -print -quit)" ]
}

# --- One profile -------------------------------------------------------------

test_profile() {
	local profile=$1 iso tag mem=2048 fwd guest_http=80 ok=0
	iso=$(ls iso/alpine-"$profile"-*-x86_64.iso 2> /dev/null | sort -V | tail -n 1)
	if [ -z "$iso" ]; then
		log "FAIL no ISO in iso/ (build it first, see README)"
		return 1
	fi
	log "image $iso"

	for port in "$HTTP_PORT" "$SSH_PORT" "$VNC_PORT"; do
		if ! port_free "$port"; then
			log "FAIL host port $port is in use (set SMOKE_PORT_BASE)"
			return 1
		fi
	done

	WORK=$(mktemp -d "${TMPDIR:-/tmp}/qemu-recipes-smoke-$profile.XXXXXX")
	mkdir "$WORK/share"

	case $profile in
		laravel) mem=1024; tag=www ;;
		node) guest_http=3000; tag=www ;;
		wordpress) tag=wordpress ;;
		x11) guest_http=6080; tag=home ;;
		*) tag=www ;;
	esac

	fwd="hostfwd=tcp:127.0.0.1:$HTTP_PORT-:$guest_http,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
	[ "$profile" = x11 ] && fwd="$fwd,hostfwd=tcp:127.0.0.1:$VNC_PORT-:5900"

	set --
	if [ "$profile" != x11 ]; then
		qemu-img create -q -f qcow2 "$WORK/db.qcow2" 4G || return 1
		set -- -drive file="$WORK/db.qcow2",if=virtio,format=qcow2
	fi

	# shellcheck disable=SC2086
	qemu-system-x86_64 $ACCEL -m "$mem" -smp 2 -cdrom "$iso" \
		-display none -serial file:"$WORK/serial.log" -monitor none \
		-nic user,model=virtio-net-pci,"$fwd" \
		-virtfs local,path="$WORK/share",mount_tag="$tag",security_model=none,id="$tag" \
		"$@" > "$WORK/qemu.log" 2>&1 &
	QEMU_PID=$!

	wait_for "boots to a login prompt" booted || ok=1
	[ $ok = 0 ] && { wait_for "sshd answers" banner "$SSH_PORT" SSH-2.0- || ok=1; }

	if [ $ok = 0 ]; then
		case $profile in
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
		ls iso/alpine-"$profile"-*-x86_64.iso > /dev/null 2>&1 \
			&& selected="$selected $profile"
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

#!/bin/sh -e
# genapkovl-x11.sh - build the boot overlay (apkovl) for the "x11" profile
# Installed by mkimg.x11.sh via profile_apkovl

HOSTNAME="${1:-alpine-x11}"

cleanup() { rm -rf "$tmp"; }
tmp="$(mktemp -d)"
trap cleanup EXIT

rc_add() {
 	# rc_add <service> <runlevel>
 	mkdir -p "$tmp"/etc/runlevels/"$2"
 	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
 }

mkdir -p "$tmp"/etc
echo "$HOSTNAME" > "$tmp"/etc/hostname

mkdir -p "$tmp"/etc/network
cat > "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modules sysctl hostname bootmisc syslog sshd; do
 	rc_add "$svc" boot
done
for svc in networking local sshd; do
 	rc_add "$svc" default
done

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

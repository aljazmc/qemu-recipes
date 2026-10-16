#!/bin/sh -e
# genapkovl-x11.sh - build the boot overlay (apkovl) for the "x11" profile
# Installed by mkimg.x11.sh via apkovl
#
# The resulting VM boots straight into an X11 desktop (openbox) that is
# served over VNC, so any Linux host can show it without extra setup:
#
#   - VNC          port 5900: any VNC viewer (vncviewer, remmina, krdc, ...)
#   - noVNC        port 6080: just a web browser,
#                  http://localhost:6080/vnc.html?autoconnect=1&resize=remote
#
# The X server is TigerVNC's Xvnc, so no (virtual) graphics card is needed;
# the desktop follows the viewer's window size and the clipboard is shared.
#
# Host <-> guest sharing of the user's home directory is done with virtio-9p.
# Start QEMU with e.g.:
#
#   mkdir -p ~/x11-home
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-x11-edge-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:5900-:5900,hostfwd=tcp:127.0.0.1:6080-:6080,hostfwd=tcp:127.0.0.1:2222-:22 \
#       -virtfs local,path="$HOME/x11-home",mount_tag=home,security_model=none,id=home
#
# and connect with "vncviewer localhost:5900" or open the noVNC URL above.
#
# - The shared directory becomes /home/<X11_USER>. The user gets the uid/gid
#   that owns it on the host, so files are editable from both sides. Nothing
#   is written into it at boot.
# - The session runs ~/.xsession when it exists and is executable, otherwise
#   openbox. Edit it from the host and log out of openbox (or restart the
#   x11-session service) to apply.
# - The user can become root with "doas" (no password). SSH login works with
#   a key in ~/.ssh/authorized_keys of the shared home (port 2222 above).
# - Without -virtfs the home directory lives in RAM and is lost on poweroff.
# - The hostfwd rules above bind to 127.0.0.1 on the host; VNC has no
#   password unless VNC_PASSWORD is set.
#
# Build-time settings (environment variables):
#   X11_USER      desktop user                          [alpine]
#   VNC_GEOMETRY  initial desktop size                  [1920x1080]
#   VNC_PASSWORD  VNC password, empty = no password     []
#
# They end up in /etc/conf.d/x11 in the guest.

HOSTNAME="${1:-x11}"

: "${X11_USER:=alpine}"
: "${VNC_GEOMETRY:=1920x1080}"
: "${VNC_PASSWORD:=}"

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
dbus
dbus-x11
doas
font-cursor-misc
font-dejavu
font-misc-misc
gcompat
glu-dev
kbd
kbd-bkeymaps
libjpeg-turbo-dev
libpng-dev
libstdc++
libuv-dev
libvorbis-dev
mbedtls-dev
mesa-dev
mesa-dri-gallium
novnc
openal-soft-dev
openbox
openssh
pipewire
pipewire-alsa
pipewire-pulse
py3-xdg
sdl3-dev
setxkbmap
sqlite-dev
tigervnc
vulkan-loader-dev
websockify
wireplumber
xauth
xkbcomp
xkeyboard-config
xrandr
xsetroot
xterm
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/x11.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the x11-* services and the session -------------------
# Readable by the desktop user: it is sourced by x11-session-run.
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0644 "$tmp"/etc/conf.d/x11 <<EOF
# Settings for /etc/init.d/x11-prep, x11-session, x11-novnc and x11-session-run

X11_USER="$X11_USER"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=home)
SHARE_TAG="home"
# uid/gid used when no host folder is shared
DEFAULT_UID="1000"
DEFAULT_GID="1000"

DISPLAY_NUM="0"
VNC_PORT="5900"
NOVNC_PORT="6080"
VNC_GEOMETRY="$VNC_GEOMETRY"
EOF

# Plain text VNC password, turned into /run/x11/vncpasswd at boot.
if [ -n "$VNC_PASSWORD" ]; then
	makefile root:root 0600 "$tmp"/etc/conf.d/x11-vncpasswd <<EOF
$VNC_PASSWORD
EOF
fi

# --- Service: mount the shared home and create the desktop user -------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/x11-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared home directory and create the desktop user"

depend() {
	need localmount
	after modules
	before x11-session x11-novnc sshd
}

. /etc/conf.d/x11

start() {
	local home="/home/$X11_USER" uid= gid= group=

	mkdir -p "$home"
	if ! mountpoint -q "$home"; then
		ebegin "Mounting host share '$SHARE_TAG' on $home"
		if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
				"$SHARE_TAG" "$home" 2>/dev/null; then
			eend 0
		else
			eend 1 "no share found, home is kept in RAM"
		fi
	fi

	if mountpoint -q "$home"; then
		uid=$(stat -c %u "$home")
		gid=$(stat -c %g "$home")
	fi
	if [ -z "$uid" ] || [ "$uid" = 0 ]; then
		uid=$DEFAULT_UID
		gid=$DEFAULT_GID
	fi

	if ! id "$X11_USER" >/dev/null 2>&1; then
		group=$(awk -F: -v id="$gid" '$3 == id { print $1; exit }' /etc/group)
		if [ -z "$group" ]; then
			group=$X11_USER
			addgroup -g "$gid" "$group"
		fi
		adduser -D -H -h "$home" -s /bin/sh -G "$group" -u "$uid" "$X11_USER"
		for g in audio video input wheel; do
			addgroup "$X11_USER" "$g" 2>/dev/null || true
		done
		# no password, but not locked either, so SSH key login works
		sed -i "s/^$X11_USER:!:/$X11_USER:*:/" /etc/shadow
	fi
	mountpoint -q "$home" || chown "$X11_USER:" "$home"

	mkdir -p /etc/doas.d
	echo "permit nopass $X11_USER" > /etc/doas.d/x11.conf
	chmod 0600 /etc/doas.d/x11.conf

	# runtime dir for the session (pipewire, dbus, ...)
	install -d -m 0700 -o "$X11_USER" -g "$(id -gn "$X11_USER")" /run/user/"$(id -u "$X11_USER")"

	install -d -m 0750 -o root -g "$(id -gn "$X11_USER")" /run/x11
	if [ -s /etc/conf.d/x11-vncpasswd ]; then
		vncpasswd -f < /etc/conf.d/x11-vncpasswd > /run/x11/vncpasswd
		chown root:"$(id -gn "$X11_USER")" /run/x11/vncpasswd
		chmod 0640 /run/x11/vncpasswd
	fi
	touch /var/log/x11-session.log /var/log/x11-novnc.log
	chown "$X11_USER" /var/log/x11-session.log /var/log/x11-novnc.log

	einfo "Desktop user: $X11_USER (uid $(id -u "$X11_USER"), home $home)"
}
EOF

# --- Service: Xvnc + desktop session -----------------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/x11-session <<'EOF'
#!/sbin/openrc-run

description="X11 desktop served over VNC (TigerVNC Xvnc + openbox)"

. /etc/conf.d/x11

supervisor=supervise-daemon
command=/usr/local/bin/x11-session-run
command_user="$X11_USER"
output_log=/var/log/x11-session.log
error_log=/var/log/x11-session.log
respawn_delay=2
respawn_max=0

depend() {
	need net x11-prep
	use dbus
}
EOF

# --- Service: noVNC (VNC in the browser) -------------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/x11-novnc <<'EOF'
#!/sbin/openrc-run

description="noVNC: the X11 desktop in a web browser"

. /etc/conf.d/x11

supervisor=supervise-daemon
command=/usr/bin/websockify
command_args="--web /usr/share/novnc $NOVNC_PORT localhost:$VNC_PORT"
command_user="$X11_USER"
output_log=/var/log/x11-novnc.log
error_log=/var/log/x11-novnc.log
respawn_delay=2
respawn_max=0

depend() {
	need net x11-prep
	after x11-session
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/x11-session-run <<'EOF'
#!/bin/sh
# x11-session-run - start Xvnc and the desktop session on it. Exits (and is
# respawned by supervise-daemon) when the session ends, e.g. on logout.

. /etc/conf.d/x11

export HOME="/home/$X11_USER"
export USER="$X11_USER" LOGNAME="$X11_USER" SHELL=/bin/sh
export DISPLAY=":$DISPLAY_NUM"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
cd "$HOME" || cd /

if [ -s /run/x11/vncpasswd ]; then
	security="-SecurityTypes VncAuth -PasswordFile /run/x11/vncpasswd"
else
	security="-SecurityTypes None"
fi

# stale lock/socket from a previous run
rm -f "/tmp/.X$DISPLAY_NUM-lock" "/tmp/.X11-unix/X$DISPLAY_NUM"

# -ac: no X access control, the X server only accepts local unix socket
# connections anyway (-nolisten tcp)
Xvnc "$DISPLAY" -ac -nolisten tcp \
	-geometry "$VNC_GEOMETRY" -depth 24 \
	-rfbport "$VNC_PORT" $security \
	-AlwaysShared -AcceptSetDesktopSize \
	-desktop "$(hostname)" &
xvnc=$!

session=
cleanup() {
	[ -n "$session" ] && kill "$session" 2>/dev/null
	kill "$xvnc" 2>/dev/null
	wait 2>/dev/null
	rm -f "/tmp/.X$DISPLAY_NUM-lock" "/tmp/.X11-unix/X$DISPLAY_NUM"
}
trap 'cleanup; exit 0' TERM INT

i=0
until [ -S "/tmp/.X11-unix/X$DISPLAY_NUM" ]; do
	i=$((i + 1))
	if [ "$i" -gt 50 ] || ! kill -0 "$xvnc" 2>/dev/null; then
		echo "x11-session-run: Xvnc did not start" >&2
		cleanup
		exit 1
	fi
	sleep 0.2
done

xsetroot -solid '#2e3440' 2>/dev/null

if [ -x "$HOME/.xsession" ]; then
	dbus-launch --exit-with-session "$HOME/.xsession" &
else
	dbus-launch --exit-with-session openbox-session &
fi
session=$!

wait "$session"
session=
cleanup
EOF

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking dbus sshd x11-prep x11-session x11-novnc; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

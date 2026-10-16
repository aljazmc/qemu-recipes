#!/bin/sh -e
# genapkovl-lamp.sh - build the boot overlay (apkovl) for the "lamp" profile
# Installed by mkimg.lamp.sh via apkovl
#
# The resulting VM boots straight into a working LAMP stack (Apache + PHP 8.4
# + MariaDB) with a ready-to-use database. Nothing has to be installed or
# configured inside the guest.
#
# Host <-> guest sharing of the served root (/var/www/html) is done with
# virtio-9p. Start QEMU with e.g.:
#
#   mkdir -p ~/lamp-dev
#   qemu-img create -f qcow2 ~/lamp-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-lamp-edge-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/lamp-dev",mount_tag=www,security_model=none,id=www \
#       -drive file="$HOME/lamp-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080.
#
# - An empty shared directory gets a starter index.php (PHP info + DB check);
#   existing files are never touched.
# - Apache/PHP run with the uid/gid that owns the shared directory on the host,
#   so files written by PHP stay editable on the host.
# - Without -virtfs the served root lives in RAM; without the extra virtio disk
#   the database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "lampdb") on first boot and
#   used for MariaDB data from then on.
#
# Build-time settings (environment variables):
#   DB_NAME      database created on boot   [app]
#   DB_USER      database user              [app]
#   DB_PASSWORD  database password          [app]
#
# They end up in /etc/conf.d/lamp in the guest.

HOSTNAME="${1:-lamp}"

: "${DB_NAME:=app}"
: "${DB_USER:=app}"
: "${DB_PASSWORD:=app}"

PHP=php84

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
apache2
blkid
e2fsprogs
mariadb
mariadb-client
openssh
$PHP
$PHP-apache2
$PHP-ctype
$PHP-curl
$PHP-dom
$PHP-fileinfo
$PHP-gd
$PHP-iconv
$PHP-intl
$PHP-mbstring
$PHP-mysqli
$PHP-opcache
$PHP-openssl
$PHP-pdo
$PHP-pdo_mysql
$PHP-phar
$PHP-session
$PHP-simplexml
$PHP-sodium
$PHP-tokenizer
$PHP-xml
$PHP-xmlreader
$PHP-xmlwriter
$PHP-zip
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/lamp.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the lamp-* services ----------------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/lamp <<EOF
# Settings for /etc/init.d/lamp-prep and /etc/init.d/lamp-init

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=www)
SHARE_TAG="www"
# filesystem label of the persistent MariaDB disk
DB_LABEL="lampdb"

DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"
EOF

# --- Apache -------------------------------------------------------------------
mkdir -p "$tmp"/etc/apache2/conf.d
makefile root:root 0644 "$tmp"/etc/apache2/conf.d/lamp.conf <<'EOF'
LoadModule rewrite_module modules/mod_rewrite.so

ServerName localhost
DocumentRoot "/var/www/html"
DirectoryIndex index.php index.html

# The served root may be a 9p share from the host; don't let Apache cache or
# sendfile() files that can change underneath it.
EnableSendfile Off
EnableMMAP Off

<Directory "/var/www/html">
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

# --- PHP ----------------------------------------------------------------------
mkdir -p "$tmp"/etc/$PHP/conf.d
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-lamp.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300

; development
display_errors = On
error_reporting = E_ALL
; pick up changes made on the host immediately
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
EOF

# --- Service: mount share, prepare DB storage, populate served root ----------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/lamp-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared web root and prepare MariaDB storage"

depend() {
	need localmount
	after modules
	before mariadb apache2
}

. /etc/conf.d/lamp

mount_share() {
	mountpoint -q "$WEBROOT" && return 0
	mkdir -p "$WEBROOT"
	ebegin "Mounting host share '$SHARE_TAG' on $WEBROOT"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$WEBROOT" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, web root is kept in RAM"
	fi
}

# Run Apache as the owner of the shared directory so the host user and
# PHP can both write to it.
setup_owner() {
	local uid= gid= user= group=

	if mountpoint -q "$WEBROOT"; then
		uid=$(stat -c %u "$WEBROOT")
		gid=$(stat -c %g "$WEBROOT")
	fi

	if [ -z "$uid" ] || [ "$uid" = 0 ]; then
		user=apache
		group=apache
	else
		group=$(awk -F: -v id="$gid" '$3 == id { print $1; exit }' /etc/group)
		if [ -z "$group" ]; then
			group=www-dev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=www-dev
			adduser -D -H -h "$WEBROOT" -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	printf 'User %s\nGroup %s\n' "$user" "$group" \
		> /etc/apache2/conf.d/zz-lamp-user.conf
	echo "$user:$group" > /run/lamp-owner
	einfo "Apache runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for MariaDB, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/lamp-data

	dev=$(blkid -L "$DB_LABEL" 2>/dev/null) || dev=
	if [ -z "$dev" ]; then
		for d in /dev/vd?; do
			[ -b "$d" ] || continue
			n=${d#/dev/}
			ls -d /sys/block/"$n"/"$n"?* >/dev/null 2>&1 && continue
			[ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] && continue
			[ -n "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null)" ] && continue
			ebegin "Formatting blank disk $d for MariaDB data"
			mkfs.ext4 -q -L "$DB_LABEL" "$d"
			eend $? || return 1
			dev=$d
			break
		done
	fi

	mkdir -p /var/lib/mysql
	if [ -n "$dev" ] && ! mountpoint -q /var/lib/mysql; then
		ebegin "Mounting $dev as MariaDB storage"
		mkdir -p "$data"
		mount -t ext4 "$dev" "$data" \
			&& mkdir -p "$data"/mysql \
			&& mount --bind "$data"/mysql /var/lib/mysql
		eend $?
	elif [ -z "$dev" ]; then
		ewarn "No persistent disk, MariaDB data is kept in RAM"
	fi
	chown mysql:mysql /var/lib/mysql

	if [ ! -d /var/lib/mysql/mysql ]; then
		ebegin "Creating MariaDB system tables"
		mariadb-install-db --user=mysql --datadir=/var/lib/mysql \
			--skip-test-db > /var/log/mariadb-install.log 2>&1
		eend $?
	fi
}

# Starter page, only written into an empty served root.
populate_webroot() {
	[ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && return 0

	ebegin "Writing starter index.php into $WEBROOT"
	cat > "$WEBROOT"/index.php <<-PHP
	<?php
	// Starter page generated by /etc/init.d/lamp-prep - replace freely.
	mysqli_report( MYSQLI_REPORT_OFF );
	\$db = @new mysqli( 'localhost', '$DB_USER', '$DB_PASSWORD', '$DB_NAME' );
	?>
	<!doctype html>
	<title>LAMP is up</title>
	<h1>LAMP is up</h1>
	<p>Served from <code><?= htmlspecialchars( __DIR__ ) ?></code></p>
	<p>MariaDB (<code>$DB_NAME</code> as <code>$DB_USER</code>):
	<?= \$db->connect_errno
		? 'connection failed: ' . htmlspecialchars( \$db->connect_error )
		: 'connected, server ' . htmlspecialchars( \$db->server_info ) ?></p>
	<?php phpinfo(); ?>
	PHP
	eend $?

	# On a 9p share (security_model=none) this is a harmless no-op.
	chown -R "$(cat /run/lamp-owner)" "$WEBROOT" 2>/dev/null || true
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot
}
EOF

# --- Service: create the application database --------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/lamp-init <<'EOF'
#!/sbin/openrc-run

description="Create the LAMP application database and user"

depend() {
	need mariadb lamp-prep
	before apache2
}

. /etc/conf.d/lamp

start() {
	ebegin "Creating database '$DB_NAME'"
	mariadb -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
	FLUSH PRIVILEGES;
	SQL
	eend $?
}
EOF

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd lamp-prep mariadb lamp-init apache2; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

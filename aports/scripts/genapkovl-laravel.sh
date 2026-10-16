#!/bin/sh -e
# genapkovl-laravel.sh - build the boot overlay (apkovl) for the "laravel" profile
# Installed by mkimg.laravel.sh via apkovl
#
# The resulting VM boots straight into a lightweight LAMP-like stack that can
# run a full Laravel project: lighttpd + PHP 8.5 (FPM) + MariaDB, Composer,
# the Laravel scheduler (cron) and a queue worker. Nothing has to be installed
# or configured inside the guest.
#
# Host <-> guest sharing of the served root (/var/www/html) is done with
# virtio-9p. Start QEMU with e.g.:
#
#   mkdir -p ~/laravel-dev
#   qemu-img create -f qcow2 ~/laravel-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 1024 -smp 2 \
#       -cdrom iso/alpine-laravel-edge-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:3307-:3306,hostfwd=tcp:127.0.0.1:2222-:22 \
#       -virtfs local,path="$HOME/laravel-dev",mount_tag=www,security_model=none,id=www \
#       -drive file="$HOME/laravel-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080.
#
# - An empty shared directory gets a new Laravel project on first boot
#   (composer create-project, needs network), configured for the MariaDB
#   database and migrated. Offline, or with LARAVEL_CREATE=no, it gets a
#   starter index.php instead. Existing files are never touched.
# - When <root>/public/index.php exists, public/ is served (Laravel, Symfony,
#   ...), otherwise the root itself. Requests for missing files go to
#   index.php. Run "rc-service lighttpd restart" after switching layouts.
# - PHP-FPM, cron and the queue worker run with the uid/gid that owns the
#   shared directory on the host, so files written by PHP (storage/, uploads)
#   stay editable on the host.
# - Laravel: "php artisan schedule:run" runs every minute and
#   "php artisan queue:listen" runs as the queue-worker service.
# - MariaDB is reachable from the host on port 3307 above (user/password
#   below).
# - Without -virtfs the served root lives in RAM; without the extra virtio
#   disk the database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "laraveldb") on first boot and
#   used for MariaDB data from then on.
#
# Build-time settings (environment variables):
#   DB_NAME          database created on boot                  [app]
#   DB_USER          database user                             [app]
#   DB_PASSWORD      database password                         [app]
#   APP_URL          URL the site is reached at from the host  [http://localhost:8080]
#   LARAVEL_CREATE   create a Laravel project in an empty root [yes]
#   LARAVEL_VERSION  laravel/laravel version constraint        [latest]
#
# They end up in /etc/conf.d/laravel in the guest.

HOSTNAME="${1:-laravel}"

: "${DB_NAME:=app}"
: "${DB_USER:=app}"
: "${DB_PASSWORD:=app}"
: "${APP_URL:=http://localhost:8080}"
: "${LARAVEL_CREATE:=yes}"
: "${LARAVEL_VERSION:=}"

# composer in Alpine depends on this PHP version
PHP=php85

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
blkid
composer
e2fsprogs
lighttpd
lighttpd-openrc
mariadb
mariadb-client
mariadb-openrc
openssh
openssh-server-common-openrc
$PHP
$PHP-bcmath
$PHP-ctype
$PHP-curl
$PHP-dom
$PHP-exif
$PHP-fileinfo
$PHP-fpm
$PHP-gd
$PHP-iconv
$PHP-intl
$PHP-mbstring
$PHP-mysqli
$PHP-openssl
$PHP-pcntl
$PHP-pdo
$PHP-pdo_mysql
$PHP-pdo_sqlite
$PHP-phar
$PHP-posix
$PHP-session
$PHP-simplexml
$PHP-sodium
$PHP-tokenizer
$PHP-xml
$PHP-xmlreader
$PHP-xmlwriter
$PHP-zip
sqlite
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/laravel.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the laravel-* services ----------------------------------
# Readable by the web user: it is sourced by laravel-queue-run.
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0644 "$tmp"/etc/conf.d/laravel <<EOF
# Settings for /etc/init.d/laravel-prep, laravel-init, laravel-queue and helpers

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=www)
SHARE_TAG="www"
# filesystem label of the persistent MariaDB disk
DB_LABEL="laraveldb"

DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"

APP_URL="$APP_URL"
LARAVEL_CREATE="$LARAVEL_CREATE"
LARAVEL_VERSION="$LARAVEL_VERSION"

PHP="$PHP"
EOF

# --- lighttpd -------------------------------------------------------------------
mkdir -p "$tmp"/etc/lighttpd
makefile root:root 0644 "$tmp"/etc/lighttpd/lighttpd.conf <<'EOF'
# lighttpd + PHP-FPM front controller setup (works for Laravel and plain PHP)

server.modules = (
    "mod_access",
    "mod_rewrite",
    "mod_fastcgi",
)

server.username  = "lighttpd"
server.groupname = "lighttpd"
server.port      = 80
server.pid-file  = "/run/lighttpd.pid"
server.errorlog  = "/var/log/lighttpd/error.log"

# The served root may be a 9p share from the host: don't cache stat() results
# or sendfile() files that can change underneath lighttpd.
server.stat-cache-engine = "disable"
server.network-backend   = "writev"

# KB, matches post_max_size
server.max-request-size = 65536

# public/ when it has an index.php (Laravel), else the root itself
include_shell "/usr/local/bin/laravel-docroot"

index-file.names = ( "index.php", "index.html" )

# hidden files (.env, .git, ...) except .well-known
$HTTP["url"] =~ "^/\.(?!well-known/)" {
    url.access-deny = ( "" )
}

# front controller: everything that isn't a file goes to index.php
url.rewrite-if-not-file = ( "" => "/index.php${url.path}${qsa}" )

fastcgi.server = (
    ".php" => ((
        "socket" => "/run/php-fpm/laravel.sock",
        "broken-scriptfilename" => "enable",
    )),
)
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/laravel-docroot <<'EOF'
#!/bin/sh
# laravel-docroot - print lighttpd's document root (used via include_shell)
. /etc/conf.d/laravel
if [ -f "$WEBROOT/public/index.php" ]; then
	echo "server.document-root = \"$WEBROOT/public\""
else
	echo "server.document-root = \"$WEBROOT\""
fi
EOF

# --- PHP ----------------------------------------------------------------------
mkdir -p "$tmp"/etc/$PHP/conf.d
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-laravel.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300

; development
display_errors = On
error_reporting = E_ALL
; pick up changes made on the host immediately
opcache.enable = 1
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
EOF

# --- MariaDB: small footprint, reachable over TCP for host tools ------------
mkdir -p "$tmp"/etc/my.cnf.d
makefile root:root 0644 "$tmp"/etc/my.cnf.d/zz-laravel.cnf <<'EOF'
[mysqld]
skip-networking = 0
bind-address = 0.0.0.0
performance_schema = OFF
innodb_buffer_pool_size = 32M
innodb_log_buffer_size = 4M
key_buffer_size = 1M
max_connections = 50
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

# --- Service: mount share, set up users, prepare DB storage -----------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/laravel-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared web root, set up the web user, prepare MariaDB storage"

depend() {
	need localmount
	after modules
	before mariadb php-fpm85 lighttpd crond laravel-init laravel-queue
}

. /etc/conf.d/laravel

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

# Run PHP as the owner of the shared directory so the host user and PHP can
# both write to it.
setup_owner() {
	local uid= gid= user= group=

	if mountpoint -q "$WEBROOT"; then
		uid=$(stat -c %u "$WEBROOT")
		gid=$(stat -c %g "$WEBROOT")
	fi

	if [ -z "$uid" ] || [ "$uid" = 0 ]; then
		group=www-dev
		user=www-dev
		addgroup -S "$group" 2>/dev/null || true
		adduser -S -D -H -h /var/cache/www-dev -s /bin/sh -G "$group" "$user" 2>/dev/null || true
	else
		group=$(awk -F: -v id="$gid" '$3 == id { print $1; exit }' /etc/group)
		if [ -z "$group" ]; then
			group=www-dev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=www-dev
			adduser -D -H -h /var/cache/www-dev -s /bin/sh -G "$group" -u "$uid" "$user"
		fi
	fi
	mountpoint -q "$WEBROOT" || chown "$user:$group" "$WEBROOT"

	# composer cache etc. must not end up in the shared directory
	install -d -o "$user" -g "$group" /var/cache/www-dev
	touch /var/log/laravel-queue.log /var/log/php-fpm-laravel.log
	chown "$user:$group" /var/log/laravel-queue.log /var/log/php-fpm-laravel.log

	# PHP-FPM pool, replaces the default "www" pool
	cat > /etc/$PHP/php-fpm.d/www.conf <<-CONF
	; Generated by /etc/init.d/laravel-prep
	[www]
	user = $user
	group = $group
	listen = /run/php-fpm/laravel.sock
	listen.owner = lighttpd
	listen.group = lighttpd
	listen.mode = 0660
	pm = ondemand
	pm.max_children = 8
	pm.process_idle_timeout = 30s
	catch_workers_output = yes
	php_admin_value[error_log] = /var/log/php-fpm-laravel.log
	CONF
	mkdir -p /run/php-fpm

	# Laravel scheduler
	cat > /etc/crontabs/"$user" <<-CRON
	* * * * * [ -f $WEBROOT/artisan ] && cd $WEBROOT && php artisan schedule:run >/dev/null 2>&1
	CRON

	echo "$user:$group" > /run/laravel-owner
	einfo "PHP runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for MariaDB, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/laravel-data

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

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
}
EOF

# --- Service: database, first-boot project -----------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/laravel-init <<'EOF'
#!/sbin/openrc-run

description="Create the application database and populate an empty web root"

depend() {
	need mariadb laravel-prep
	use net
	before lighttpd php-fpm85 laravel-queue
}

. /etc/conf.d/laravel

as_owner() {
	su -s /bin/sh "${owner%%:*}" -c "umask 022; export HOME=/var/cache/www-dev; $1"
}

create_db() {
	ebegin "Creating database '$DB_NAME'"
	mariadb -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
	CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
	CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
	FLUSH PRIVILEGES;
	SQL
	eend $?
}

# composer create-project straight into the (empty) web root. The root
# filesystem is a RAM disk too small for a full vendor/, so nothing big may
# land there: no composer cache, no temp copy.
create_laravel() {
	local pkg=laravel/laravel

	[ -n "$LARAVEL_VERSION" ] && pkg="$pkg:$LARAVEL_VERSION"

	ebegin "Creating Laravel project (composer, needs network)"
	if as_owner "COMPOSER_NO_CACHE=1 composer create-project --no-cache --no-interaction --no-progress --prefer-dist $pkg $WEBROOT" \
			> /var/log/laravel-create.log 2>&1; then
		eend 0
	else
		eend 1 "see /var/log/laravel-create.log"
		# leave the root empty again, the starter page goes in instead
		find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
		return 1
	fi

	# point .env at MariaDB
	sed -i -E \
		-e '/^#? ?DB_(CONNECTION|HOST|PORT|DATABASE|USERNAME|PASSWORD|SOCKET)=/d' \
		-e '/^APP_URL=/d' \
		"$WEBROOT"/.env
	cat >> "$WEBROOT"/.env <<-ENV

	APP_URL=$APP_URL
	DB_CONNECTION=mysql
	DB_HOST=localhost
	DB_PORT=3306
	DB_SOCKET=/run/mysqld/mysqld.sock
	DB_DATABASE=$DB_NAME
	DB_USERNAME=$DB_USER
	DB_PASSWORD=$DB_PASSWORD
	ENV
	rm -f "$WEBROOT"/database/database.sqlite

	ebegin "Running Laravel migrations"
	as_owner "cd $WEBROOT && php artisan migrate --force --no-interaction" \
		>> /var/log/laravel-create.log 2>&1
	eend $?
}

create_starter() {
	ebegin "Writing starter index.php into $WEBROOT"
	cat > "$WEBROOT"/index.php <<-PHP
	<?php
	// Starter page generated by /etc/init.d/laravel-init - replace freely.
	mysqli_report( MYSQLI_REPORT_OFF );
	\$db = @new mysqli( 'localhost', '$DB_USER', '$DB_PASSWORD', '$DB_NAME' );
	?>
	<!doctype html>
	<title>lighttpd + PHP is up</title>
	<h1>lighttpd + PHP is up</h1>
	<p>Served from <code><?= htmlspecialchars( __DIR__ ) ?></code></p>
	<p>MariaDB (<code>$DB_NAME</code> as <code>$DB_USER</code>):
	<?= \$db->connect_errno
		? 'connection failed: ' . htmlspecialchars( \$db->connect_error )
		: 'connected, server ' . htmlspecialchars( \$db->server_info ) ?></p>
	<?php phpinfo(); ?>
	PHP
	eend $?
	chown "$owner" "$WEBROOT"/index.php 2>/dev/null || true
}

start() {
	owner=$(cat /run/laravel-owner)

	create_db || return 1

	[ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && return 0
	if [ "$LARAVEL_CREATE" = yes ] && create_laravel; then
		return 0
	fi
	create_starter
}
EOF

# --- Service: Laravel queue worker -------------------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/laravel-queue <<'EOF'
#!/sbin/openrc-run

description="Laravel queue worker (idle when the web root has no artisan)"

supervisor=supervise-daemon
command=/usr/local/bin/laravel-queue-run
output_log=/var/log/laravel-queue.log
error_log=/var/log/laravel-queue.log
respawn_delay=5
respawn_max=0

depend() {
	need laravel-prep mariadb
	after laravel-init
}

start_pre() {
	command_user=$(cat /run/laravel-owner)
}
EOF

makefile root:root 0755 "$tmp"/usr/local/bin/laravel-queue-run <<'EOF'
#!/bin/sh
# laravel-queue-run - run "php artisan queue:listen" once the web root is a
# Laravel project. queue:listen boots the app per job, so code changes made
# on the host are picked up without restarting.
. /etc/conf.d/laravel
export HOME=/var/cache/www-dev
cd "$WEBROOT" || exit 1
while [ ! -f artisan ] || [ ! -d vendor ]; do
	sleep 10
done
exec php artisan queue:listen --tries=3
EOF

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd crond laravel-prep mariadb laravel-init php-fpm85 lighttpd laravel-queue; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

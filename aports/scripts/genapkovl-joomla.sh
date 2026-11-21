#!/bin/sh -e
# genapkovl-joomla.sh - build the boot overlay (apkovl) for the "joomla" profile
# Installed by mkimg.joomla.sh via apkovl
#
# The resulting VM boots straight into a working, already installed Joomla
# site (Apache + PHP 8.4 + MariaDB). Nothing has to be installed or configured
# inside the guest.
#
# Host <-> guest sharing of the webroot (/var/www/html) is done with virtio-9p.
# Start QEMU with e.g.:
#
#   mkdir -p ~/joomla-dev
#   qemu-img create -f qcow2 ~/joomla-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-joomla-v3.24-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/joomla-dev",mount_tag=joomla,security_model=none,id=joomla \
#       -drive file="$HOME/joomla-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080 (admin: http://localhost:8080/administrator).
#
# - An empty shared directory is populated with Joomla on first boot and the
#   site is installed with Joomla's CLI installer. A directory with files of
#   its own is served as it is.
# - The installer runs again whenever the database is empty and
#   configuration.php points at the database created here, so without a
#   database disk the site is reinstalled on every boot (configuration.php is
#   kept).
# - Apache/PHP run with the uid/gid that owns the shared directory on the host,
#   so files created by Joomla (media, extensions) stay editable on the host.
# - Without -virtfs the webroot lives in RAM; without the extra virtio disk the
#   database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "joomladb") on first boot and
#   used for MariaDB data from then on.
#
# Build-time settings (environment variables):
#   JOOMLA_SITE_NAME       site name                          [Joomla Dev]
#   JOOMLA_ADMIN_USER      admin login                        [admin]
#   JOOMLA_ADMIN_PASSWORD  admin password, 12+ characters     [admin-password]
#   JOOMLA_ADMIN_EMAIL     admin e-mail                       [admin@example.com]
#   JOOMLA_VERSION         Joomla version to bundle           [latest]
#   JOOMLA_TARBALL         local Joomla Full_Package tarball to bundle instead
#                          of downloading
#
# All of them (plus DB credentials) end up in /etc/conf.d/joomla in the guest.

HOSTNAME="${1:-joomla}"

: "${JOOMLA_SITE_NAME:=Joomla Dev}"
: "${JOOMLA_ADMIN_USER:=admin}"
: "${JOOMLA_ADMIN_PASSWORD:=admin-password}"
: "${JOOMLA_ADMIN_EMAIL:=admin@example.com}"
: "${JOOMLA_VERSION:=latest}"

if [ ${#JOOMLA_ADMIN_PASSWORD} -lt 12 ]; then
	echo "ERROR: JOOMLA_ADMIN_PASSWORD must have at least 12 characters (Joomla rule)" >&2
	exit 1
fi

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
apache2-openrc
blkid
e2fsprogs
mariadb
mariadb-client
mariadb-openrc
openssh
openssh-server-common-openrc
$PHP
$PHP-apache2
$PHP-ctype
$PHP-curl
$PHP-dom
$PHP-exif
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
$PHP-pecl-apcu
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
$PHP-zlib
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/joomla.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the joomla-* services --------------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/joomla <<EOF
# Settings for /etc/init.d/joomla-prep and /etc/init.d/joomla-init

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=joomla)
SHARE_TAG="joomla"
# filesystem label of the persistent MariaDB disk
DB_LABEL="joomladb"

DB_NAME="joomla"
DB_USER="joomla"
DB_PASSWORD="joomla"
DB_PREFIX="jos_"

JOOMLA_SITE_NAME="$JOOMLA_SITE_NAME"
JOOMLA_ADMIN_USER="$JOOMLA_ADMIN_USER"
JOOMLA_ADMIN_PASSWORD="$JOOMLA_ADMIN_PASSWORD"
JOOMLA_ADMIN_EMAIL="$JOOMLA_ADMIN_EMAIL"

PHP="$PHP"
EOF

# --- Apache -------------------------------------------------------------------
mkdir -p "$tmp"/etc/apache2/conf.d
makefile root:root 0644 "$tmp"/etc/apache2/conf.d/joomla.conf <<'EOF'
LoadModule rewrite_module modules/mod_rewrite.so

ServerName localhost
DocumentRoot "/var/www/html"
DirectoryIndex index.php index.html

# The webroot may be a 9p share from the host; don't let Apache cache or
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
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-joomla.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
output_buffering = Off

; development: pick up changes made on the host immediately
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
EOF

# --- Service: mount share, prepare DB storage, populate webroot --------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/joomla-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared Joomla webroot and prepare MariaDB storage"

depend() {
	need localmount
	after modules
	before mariadb apache2
}

. /etc/conf.d/joomla

mount_share() {
	mountpoint -q "$WEBROOT" && return 0
	mkdir -p "$WEBROOT"
	ebegin "Mounting host share '$SHARE_TAG' on $WEBROOT"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$WEBROOT" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, webroot is kept in RAM"
	fi
}

# Run Apache as the owner of the shared directory so the host user and
# Joomla can both write to it.
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
			group=joomladev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=joomladev
			adduser -D -H -h "$WEBROOT" -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	printf 'User %s\nGroup %s\n' "$user" "$group" \
		> /etc/apache2/conf.d/zz-joomla-user.conf
	echo "$user:$group" > /run/joomla-owner
	einfo "Apache runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for MariaDB, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/joomla-data

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

# copy_tree <src> <dst>: copy the contents of <src> into the directory <dst>.
# Extracting straight onto the 9p share costs ~12 ms per file (tar restores
# owner, mode and times of every entry), so a tarball is unpacked in RAM and
# copied with plain cp, 8 subtrees at a time: several times
# faster.
copy_tree() {
	(
		cd "$1" || exit 1
		find . -mindepth 1 -maxdepth 2 -type d | while read -r d; do
			mkdir -p "$2/$d"
		done
		find . -mindepth 1 -maxdepth 2 ! -type d | while read -r f; do
			cp "$f" "$2/$f"
		done
		find . -mindepth 2 -maxdepth 2 -type d \
			| xargs -r -P 8 -I{} cp -r "{}/." "$2/{}/"
	)
}

populate_webroot() {
	local owner src=/usr/share/joomla/joomla.tar.gz tmp

	owner=$(cat /run/joomla-owner)

	if [ -z "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
		ebegin "Installing Joomla files into $WEBROOT"
		tmp=$(mktemp -d)
		if [ ! -f "$src" ]; then
			# not bundled at build time, fall back to the network
			src="$tmp"/joomla.tar.gz
			wget -q -O - https://api.github.com/repos/joomla/joomla-cms/releases/latest \
				| sed -n 's#.*"browser_download_url": *"\([^"]*-Stable-Full_Package\.tar\.gz\)".*#\1#p' \
				| head -n 1 | xargs -r wget -q -O "$src"
		fi
		# the Full_Package tarball has no top-level directory
		mkdir "$tmp"/joomla \
			&& tar -xzf "$src" -C "$tmp"/joomla \
			&& copy_tree "$tmp"/joomla "$WEBROOT"
		[ -f "$WEBROOT"/installation/joomla.php ]
		eend $? "could not install Joomla files"
		rm -rf "$tmp"
	fi

	if [ -f "$WEBROOT"/htaccess.txt ] && [ ! -f "$WEBROOT"/.htaccess ]; then
		cp "$WEBROOT"/htaccess.txt "$WEBROOT"/.htaccess
	fi

	# Only for a webroot in RAM: on a 9p share (security_model=none) files
	# belong to the host user anyway, and walking every file takes a while.
	mountpoint -q "$WEBROOT" || chown -R "$owner" "$WEBROOT" 2>/dev/null || true
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot
}
EOF

# --- Service: create database and run the Joomla installer ------------------
makefile root:root 0755 "$tmp"/etc/init.d/joomla-init <<'EOF'
#!/sbin/openrc-run

description="Create the Joomla database and install the site"

depend() {
	need mariadb joomla-prep
	before apache2
}

. /etc/conf.d/joomla

# Value of a property of JConfig in configuration.php
config_get() {
	$PHP -r 'require $argv[1]; $c = new JConfig; echo $c->{$argv[2]} ?? "";' \
		"$WEBROOT"/configuration.php "$1" 2>/dev/null
}

# run_as_owner <command>: run a shell command in $WEBROOT as the share owner.
# Settings reach it through the environment (exported in start), so values
# with quotes or spaces are safe.
run_as_owner() {
	su -s /bin/sh "${owner%%:*}" -c "cd \"\$WEBROOT\" && $1"
}

# install_site <table prefix>
install_site() {
	export INSTALL_PREFIX="$1"
	run_as_owner '"$PHP" installation/joomla.php install \
		--no-interaction --site-name="$JOOMLA_SITE_NAME" \
		--admin-user="Super User" --admin-username="$JOOMLA_ADMIN_USER" \
		--admin-password="$JOOMLA_ADMIN_PASSWORD" \
		--admin-email="$JOOMLA_ADMIN_EMAIL" --db-type=mysqli \
		--db-host=localhost --db-user="$DB_USER" --db-pass="$DB_PASSWORD" \
		--db-name="$DB_NAME" --db-prefix="$INSTALL_PREFIX" --db-encryption=0'
}

start() {
	local owner prefix tables rc=1
	export WEBROOT PHP DB_NAME DB_USER DB_PASSWORD JOOMLA_SITE_NAME \
		JOOMLA_ADMIN_USER JOOMLA_ADMIN_PASSWORD JOOMLA_ADMIN_EMAIL
	export JOOMLA_TARBALL=/usr/share/joomla/joomla.tar.gz

	ebegin "Creating Joomla database"
	mariadb -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
	FLUSH PRIVILEGES;
	SQL
	eend $? || return 1

	owner=$(cat /run/joomla-owner)

	if [ ! -f "$WEBROOT"/configuration.php ]; then
		[ -f "$WEBROOT"/installation/joomla.php ] || return 0
		ebegin "Installing Joomla site"
		install_site "$DB_PREFIX" > /var/log/joomla-install.log 2>&1 \
			&& run_as_owner '"$PHP" cli/joomla.php config:set \
				sef_rewrite=true error_reporting=maximum' \
				>> /var/log/joomla-install.log 2>&1
		eend $? "Joomla install failed, see /var/log/joomla-install.log"
		return
	fi

	# An existing site of ours with an empty database (no database disk):
	# install again into it, keeping configuration.php.
	[ "$(config_get db)" = "$DB_NAME" ] || return 0
	prefix=$(config_get dbprefix)
	tables=$(mariadb -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables
		WHERE table_schema = '$DB_NAME' AND table_name = '${prefix}users'")
	[ "$tables" = 0 ] || return 0
	if [ ! -f "$JOOMLA_TARBALL" ]; then
		ewarn "Joomla database is empty and no installer is bundled"
		return 0
	fi

	ebegin "Reinstalling Joomla into the empty database"
	if run_as_owner 'tar -xzf "$JOOMLA_TARBALL" installation \
			&& mv configuration.php configuration.php.qemu-recipes' \
			> /var/log/joomla-install.log 2>&1; then
		install_site "$prefix" >> /var/log/joomla-install.log 2>&1
		rc=$?
	fi
	# keep the configuration the user already had, whatever happened
	run_as_owner '[ ! -f configuration.php.qemu-recipes ] \
		|| mv -f configuration.php.qemu-recipes configuration.php; rm -rf installation' \
		>> /var/log/joomla-install.log 2>&1
	eend $rc "Joomla install failed, see /var/log/joomla-install.log"
}
EOF

# --- Bundle Joomla so the first boot works offline --------------------------
# From the GitHub release: the Full_Package tarball and its sha256 digest.
mkdir -p "$tmp"/usr/share/joomla
if [ -n "$JOOMLA_TARBALL" ]; then
	cp "$JOOMLA_TARBALL" "$tmp"/usr/share/joomla/joomla.tar.gz
else
	case "$JOOMLA_VERSION" in
	latest) api=https://api.github.com/repos/joomla/joomla-cms/releases/latest ;;
	*) api=https://api.github.com/repos/joomla/joomla-cms/releases/tags/$JOOMLA_VERSION ;;
	esac
	if meta=$(wget -q -O - "$api") \
		&& url=$(echo "$meta" | sed -n 's/.*"browser_download_url": *"\([^"]*-Stable-Full_Package\.tar\.gz\)".*/\1/p' | head -n 1) \
		&& sha256=$(echo "$meta" \
			| awk '/"name": *"Joomla_[^"]*-Stable-Full_Package\.tar\.gz"/ { f = 1 } f && /"digest"/ { print; exit }' \
			| sed -n 's/.*"sha256:\([0-9a-f]*\)".*/\1/p') \
		&& [ -n "$url" ] && [ -n "$sha256" ] \
		&& wget -q -O "$tmp"/usr/share/joomla/joomla.tar.gz "$url" \
		&& echo "$sha256  $tmp/usr/share/joomla/joomla.tar.gz" | sha256sum -c >/dev/null; then
		:
	else
		echo "WARNING: could not bundle Joomla, guest will download it on first boot" >&2
		rm -f "$tmp"/usr/share/joomla/joomla.tar.gz
	fi
fi

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd joomla-prep mariadb joomla-init apache2; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

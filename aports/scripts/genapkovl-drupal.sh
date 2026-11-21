#!/bin/sh -e
# genapkovl-drupal.sh - build the boot overlay (apkovl) for the "drupal" profile
# Installed by mkimg.drupal.sh via apkovl
#
# The resulting VM boots straight into a working, already installed Drupal
# site (Apache + PHP 8.4 + MariaDB). Nothing has to be installed or configured
# inside the guest.
#
# Host <-> guest sharing of the webroot (/var/www/html) is done with virtio-9p.
# Start QEMU with e.g.:
#
#   mkdir -p ~/drupal-dev
#   qemu-img create -f qcow2 ~/drupal-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-drupal-v3.24-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/drupal-dev",mount_tag=drupal,security_model=none,id=drupal \
#       -drive file="$HOME/drupal-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080 (log in at http://localhost:8080/user/login).
#
# - An empty shared directory is populated with Drupal core on first boot and
#   the site is installed (profile DRUPAL_PROFILE). A directory that already
#   holds a Drupal site is served as it is: the tarball layout (core/ at the
#   top) or a Composer project (drupal/recommended-project, docroot web/).
# - The installer runs whenever the database is empty and settings.php is the
#   one written here, so without a database disk the site is reinstalled on
#   every boot. A settings.php of your own is never touched.
# - Apache/PHP run with the uid/gid that owns the shared directory on the host,
#   so files created by Drupal (uploads, config exports) stay editable on the
#   host.
# - Without -virtfs the webroot lives in RAM; without the extra virtio disk the
#   database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "drupaldb") on first boot and
#   used for MariaDB data from then on.
#
# Build-time settings (environment variables):
#   DRUPAL_SITE_NAME       site name                               [Drupal Dev]
#   DRUPAL_ADMIN_USER      admin login                             [admin]
#   DRUPAL_ADMIN_PASSWORD  admin password                          [admin]
#   DRUPAL_ADMIN_EMAIL     admin e-mail                            [admin@example.com]
#   DRUPAL_PROFILE         install profile (standard, minimal, ...) [standard]
#   DRUPAL_VERSION         Drupal version to bundle                [latest]
#   DRUPAL_TARBALL         local Drupal tarball to bundle instead of downloading
#
# All of them (plus DB credentials) end up in /etc/conf.d/drupal in the guest.

HOSTNAME="${1:-drupal}"

: "${DRUPAL_SITE_NAME:=Drupal Dev}"
: "${DRUPAL_ADMIN_USER:=admin}"
: "${DRUPAL_ADMIN_PASSWORD:=admin}"
: "${DRUPAL_ADMIN_EMAIL:=admin@example.com}"
: "${DRUPAL_PROFILE:=standard}"
: "${DRUPAL_VERSION:=latest}"

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

# Agents and the monitoring network, shared by all profiles
. "$(dirname "$0")"/monitoring-agent.sh

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
$PHP-fileinfo
$PHP-gd
$PHP-iconv
$PHP-intl
$PHP-mbstring
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
makefile root:root 0644 "$tmp"/etc/modules-load.d/drupal.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the drupal-* services --------------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/drupal <<EOF
# Settings for /etc/init.d/drupal-prep and /etc/init.d/drupal-init

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=drupal)
SHARE_TAG="drupal"
# filesystem label of the persistent MariaDB disk
DB_LABEL="drupaldb"

DB_NAME="drupal"
DB_USER="drupal"
DB_PASSWORD="drupal"

DRUPAL_SITE_NAME="$DRUPAL_SITE_NAME"
DRUPAL_ADMIN_USER="$DRUPAL_ADMIN_USER"
DRUPAL_ADMIN_PASSWORD="$DRUPAL_ADMIN_PASSWORD"
DRUPAL_ADMIN_EMAIL="$DRUPAL_ADMIN_EMAIL"
DRUPAL_PROFILE="$DRUPAL_PROFILE"

PHP="$PHP"
EOF

# --- Apache -------------------------------------------------------------------
# DocumentRoot is set at boot by drupal-prep (zz-drupal-docroot.conf), since a
# Composer project is served from web/.
mkdir -p "$tmp"/etc/apache2/conf.d
makefile root:root 0644 "$tmp"/etc/apache2/conf.d/drupal.conf <<'EOF'
LoadModule rewrite_module modules/mod_rewrite.so

ServerName localhost
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
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-drupal.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 512M
max_execution_time = 300

; development: pick up changes made on the host immediately
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
EOF

# --- Service: mount share, prepare DB storage, populate webroot --------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/drupal-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared Drupal webroot and prepare MariaDB storage"

depend() {
	need localmount
	after modules
	before mariadb apache2
}

. /etc/conf.d/drupal

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
# Drupal can both write to it.
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
			group=drupaldev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=drupaldev
			adduser -D -H -h "$WEBROOT" -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	printf 'User %s\nGroup %s\n' "$user" "$group" \
		> /etc/apache2/conf.d/zz-drupal-user.conf
	echo "$user:$group" > /run/drupal-owner
	einfo "Apache runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for MariaDB, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/drupal-data

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

# The directory with Drupal's index.php: the share itself (tarball layout)
# or web/ (Composer project).
find_docroot() {
	if [ -f "$WEBROOT"/web/core/lib/Drupal.php ]; then
		echo "$WEBROOT"/web
	else
		echo "$WEBROOT"
	fi
}

write_settings() {
	local docroot=$1 salt
	salt=$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 64)
	cp "$docroot"/sites/default/default.settings.php "$docroot"/sites/default/settings.php
	cat >> "$docroot"/sites/default/settings.php <<-PHP

	// --- Added on first boot by /etc/init.d/drupal-prep (development VM) ---
	// drupal-init (re)installs the site while this marker is here and the
	// database is empty. Remove this line to stop that.
	// qemu-recipes: managed

	\$databases['default']['default'] = [
	  'driver' => 'mysql',
	  'namespace' => 'Drupal\\\\mysql\\\\Driver\\\\Database\\\\mysql',
	  'autoload' => 'core/modules/mysql/src/Driver/Database/mysql/',
	  'database' => '$DB_NAME',
	  'username' => '$DB_USER',
	  'password' => '$DB_PASSWORD',
	  'host' => 'localhost',
	  'unix_socket' => '/run/mysqld/mysqld.sock',
	  'prefix' => '',
	  'isolation_level' => 'READ COMMITTED',
	];
	\$settings['hash_salt'] = '$salt';
	\$settings['config_sync_directory'] = 'sites/default/files/sync';

	// Any host/port the site is reached at (e.g. QEMU hostfwd).
	\$settings['trusted_host_patterns'] = ['.*'];

	// Development: show all errors, no CSS/JS aggregation, and don't make
	// sites/default read-only (it is edited from the host).
	\$config['system.logging']['error_level'] = 'verbose';
	\$config['system.performance']['css']['preprocess'] = FALSE;
	\$config['system.performance']['js']['preprocess'] = FALSE;
	\$settings['skip_permissions_hardening'] = TRUE;
	PHP
}

# copy_tree <src> <dst>: copy the contents of <src> into the directory <dst>.
# Extracting straight onto the 9p share costs ~12 ms per file (tar restores
# owner, mode and times of every entry), so a tarball is unpacked in RAM and
# copied with plain cp, 8 subtrees at a time: 31k files in ~1 minute
# instead of ~6.
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
	local owner docroot src=/usr/share/drupal/drupal.tar.gz tmp

	owner=$(cat /run/drupal-owner)

	if [ ! -f "$WEBROOT"/core/lib/Drupal.php ] \
			&& [ ! -f "$WEBROOT"/web/core/lib/Drupal.php ]; then
		if [ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
			ewarn "$WEBROOT holds no Drupal site, serving it as it is"
			return 0
		fi
		ebegin "Installing Drupal core files into $WEBROOT"
		tmp=$(mktemp -d)
		if [ ! -f "$src" ]; then
			# not bundled at build time, fall back to the network
			src="$tmp"/drupal.tar.gz
			wget -q -O "$src" https://www.drupal.org/download-latest/tar.gz
		fi
		mkdir "$tmp"/drupal \
			&& tar -xzf "$src" -C "$tmp"/drupal --strip-components=1 \
			&& copy_tree "$tmp"/drupal "$WEBROOT"
		[ -f "$WEBROOT"/core/lib/Drupal.php ]
		eend $? "could not install Drupal core files"
		rm -rf "$tmp"
		[ -f "$WEBROOT"/core/lib/Drupal.php ] || return 1
	fi

	docroot=$(find_docroot)
	if [ ! -f "$docroot"/sites/default/settings.php ] \
			&& [ -f "$docroot"/sites/default/default.settings.php ]; then
		write_settings "$docroot"
	fi

	# Only for a webroot in RAM: on a 9p share (security_model=none) files
	# belong to the host user anyway, and walking 30k files takes a while.
	mountpoint -q "$WEBROOT" || chown -R "$owner" "$WEBROOT" 2>/dev/null || true
}

setup_docroot() {
	local docroot
	docroot=$(find_docroot)
	cat > /etc/apache2/conf.d/zz-drupal-docroot.conf <<-CONF
	DocumentRoot "$docroot"
	<Directory "$docroot">
	    Options FollowSymLinks
	    AllowOverride All
	    Require all granted
	</Directory>
	CONF
	echo "$docroot" > /run/drupal-docroot
	einfo "Serving $docroot"
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot || return 1
	setup_docroot
}
EOF

# --- Service: create database and run the Drupal installer ------------------
makefile root:root 0755 "$tmp"/etc/init.d/drupal-init <<'EOF'
#!/sbin/openrc-run

description="Create the Drupal database and install the site"

depend() {
	need mariadb drupal-prep
	before apache2
}

. /etc/conf.d/drupal

start() {
	local owner docroot tables

	ebegin "Creating Drupal database"
	mariadb -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
	CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
	FLUSH PRIVILEGES;
	SQL
	eend $? || return 1

	docroot=$(cat /run/drupal-docroot)
	# only a site whose settings.php was written by drupal-prep
	grep -qs '^// qemu-recipes: managed' "$docroot"/sites/default/settings.php \
		|| return 0
	tables=$(mariadb -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables
		WHERE table_schema = '$DB_NAME' AND table_name = 'users'")
	[ "$tables" = 0 ] || return 0

	ebegin "Installing Drupal site (profile $DRUPAL_PROFILE)"
	owner=$(cat /run/drupal-owner)
	WEBROOT="$docroot" SITE_NAME="$DRUPAL_SITE_NAME" \
	ADMIN_USER="$DRUPAL_ADMIN_USER" ADMIN_PASSWORD="$DRUPAL_ADMIN_PASSWORD" \
	ADMIN_EMAIL="$DRUPAL_ADMIN_EMAIL" PROFILE="$DRUPAL_PROFILE" \
		su -s /bin/sh "${owner%%:*}" -c "$PHP /usr/share/drupal/install.php" \
		> /var/log/drupal-install.log 2>&1
	eend $? "Drupal install failed, see /var/log/drupal-install.log"
}
EOF

mkdir -p "$tmp"/usr/share/drupal
makefile root:root 0644 "$tmp"/usr/share/drupal/install.php <<'EOF'
<?php
// Non-interactive Drupal install, run by /etc/init.d/drupal-init.
// Same approach as "drush site:install": call install_drupal() with every
// installer form answered in advance. The database settings come from
// settings.php.

$root = getenv('WEBROOT');
chdir($root);
$class_loader = require $root . '/autoload.php';

$_SERVER['HTTP_HOST']       = 'localhost';
$_SERVER['SERVER_NAME']     = 'localhost';
$_SERVER['SERVER_PORT']     = 80;
$_SERVER['REQUEST_URI']     = '/';
$_SERVER['REQUEST_METHOD']  = 'GET';
$_SERVER['SCRIPT_NAME']     = '/index.php';
$_SERVER['SCRIPT_FILENAME'] = $root . '/index.php';
$_SERVER['PHP_SELF']        = '/index.php';
$_SERVER['REMOTE_ADDR']     = '127.0.0.1';
$_SERVER['SERVER_SOFTWARE'] = 'Apache';

require_once $root . '/core/includes/install.core.inc';

$pass = getenv('ADMIN_PASSWORD');
install_drupal($class_loader, [
	'interactive' => FALSE,
	'parameters' => [
		'profile' => getenv('PROFILE') ?: 'standard',
		'langcode' => 'en',
	],
	'forms' => [
		'install_configure_form' => [
			'site_name' => getenv('SITE_NAME'),
			'site_mail' => getenv('ADMIN_EMAIL'),
			'account' => [
				'name' => getenv('ADMIN_USER'),
				'mail' => getenv('ADMIN_EMAIL'),
				'pass' => ['pass1' => $pass, 'pass2' => $pass],
			],
			'enable_update_status_module' => TRUE,
			'enable_update_status_emails' => FALSE,
			'site_default_country' => '',
			'date_default_timezone' => 'UTC',
		],
	],
]);
EOF

# --- Bundle Drupal so the first boot works offline --------------------------
# The release feed lists every release with its tarball and md5; "latest" is
# the newest one without a pre-release suffix (-beta1, -rc1, ...).
if [ -n "$DRUPAL_TARBALL" ]; then
	cp "$DRUPAL_TARBALL" "$tmp"/usr/share/drupal/drupal.tar.gz
else
	if release=$(wget -q -O - https://updates.drupal.org/release-history/drupal/current \
			| tr -d '\n\t' | sed 's#<release>#\n#g' \
			| if [ "$DRUPAL_VERSION" = latest ]; then
				grep -m 1 '<version>[0-9]*\.[0-9]*\.[0-9]*</version>'
			else
				grep -m 1 "<version>$DRUPAL_VERSION</version>"
			fi) \
		&& url=$(echo "$release" | sed -n 's#.*<file><url>\([^<]*\.tar\.gz\)</url>.*#\1#p') \
		&& md5=$(echo "$release" | sed -n 's#.*\.tar\.gz</url><archive_type>tar\.gz</archive_type><md5>\([0-9a-f]*\)</md5>.*#\1#p') \
		&& [ -n "$url" ] && [ -n "$md5" ] \
		&& wget -q -O "$tmp"/usr/share/drupal/drupal.tar.gz "$url" \
		&& echo "$md5  $tmp/usr/share/drupal/drupal.tar.gz" | md5sum -c >/dev/null; then
		:
	else
		echo "WARNING: could not bundle Drupal, guest will download it on first boot" >&2
		rm -f "$tmp"/usr/share/drupal/drupal.tar.gz
	fi
fi

# --- Monitoring agents (see monitoring-agent.sh) ---------------------------
monitoring_agent drupal

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd drupal-prep mariadb drupal-init apache2; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

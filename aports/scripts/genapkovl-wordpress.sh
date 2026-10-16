#!/bin/sh -e
# genapkovl-wordpress.sh - build the boot overlay (apkovl) for the "wordpress" profile
# Installed by mkimg.wordpress.sh via apkovl
#
# The resulting VM boots straight into a working, already installed WordPress
# site (Apache + PHP 8.4 + MariaDB). Nothing has to be installed or configured
# inside the guest.
#
# Host <-> guest sharing of the webroot (/var/www/html) is done with virtio-9p.
# Start QEMU with e.g.:
#
#   mkdir -p ~/wordpress-dev ~/wordpress-db
#   qemu-img create -f qcow2 ~/wordpress-db/db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-wordpress-edge-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/wordpress-dev",mount_tag=wordpress,security_model=none,id=wordpress \
#       -drive file="$HOME/wordpress-db/db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080 (admin: http://localhost:8080/wp-admin).
#
# - An empty shared directory is populated with WordPress core on first boot;
#   existing files are never overwritten, so it can hold your own project.
# - Apache/PHP run with the uid/gid that owns the shared directory on the host,
#   so files created by WordPress (uploads, plugins) stay editable on the host.
# - Without -virtfs the webroot lives in RAM; without the extra virtio disk the
#   database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "wpdb") on first boot and used
#   for MariaDB data from then on.
#
# Build-time settings (environment variables):
#   WP_URL             URL the site is reached at from the host  [http://localhost:8080]
#   WP_TITLE           site title                                 [WordPress Dev]
#   WP_ADMIN_USER      admin login                                [admin]
#   WP_ADMIN_PASSWORD  admin password                             [admin]
#   WP_ADMIN_EMAIL     admin e-mail                               [admin@example.com]
#   WP_VERSION         WordPress version to bundle                [latest]
#   WP_TARBALL         local WordPress tarball to bundle instead of downloading
#
# All of them (plus DB credentials) end up in /etc/conf.d/wordpress in the guest.

HOSTNAME="${1:-wordpress}"

: "${WP_URL:=http://localhost:8080}"
: "${WP_TITLE:=WordPress Dev}"
: "${WP_ADMIN_USER:=admin}"
: "${WP_ADMIN_PASSWORD:=admin}"
: "${WP_ADMIN_EMAIL:=admin@example.com}"
: "${WP_VERSION:=latest}"

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
$PHP-exif
$PHP-fileinfo
$PHP-gd
$PHP-iconv
$PHP-intl
$PHP-mbstring
$PHP-mysqli
$PHP-opcache
$PHP-openssl
$PHP-pecl-apcu
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
makefile root:root 0644 "$tmp"/etc/modules-load.d/wordpress.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the wordpress-* services -----------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/wordpress <<EOF
# Settings for /etc/init.d/wordpress-prep and /etc/init.d/wordpress-init

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=wordpress)
SHARE_TAG="wordpress"
# filesystem label of the persistent MariaDB disk
DB_LABEL="wpdb"

DB_NAME="wordpress"
DB_USER="wordpress"
DB_PASSWORD="wordpress"

WP_URL="$WP_URL"
WP_TITLE="$WP_TITLE"
WP_ADMIN_USER="$WP_ADMIN_USER"
WP_ADMIN_PASSWORD="$WP_ADMIN_PASSWORD"
WP_ADMIN_EMAIL="$WP_ADMIN_EMAIL"

PHP="$PHP"
EOF

# --- Apache -------------------------------------------------------------------
mkdir -p "$tmp"/etc/apache2/conf.d
makefile root:root 0644 "$tmp"/etc/apache2/conf.d/wordpress.conf <<'EOF'
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
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-wordpress.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300

; development: pick up changes made on the host immediately
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
EOF

# --- Service: mount share, prepare DB storage, populate webroot --------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/wordpress-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared WordPress webroot and prepare MariaDB storage"

depend() {
	need localmount
	after modules
	before mariadb apache2
}

. /etc/conf.d/wordpress

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
# WordPress can both write to it.
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
			group=wpdev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=wpdev
			adduser -D -H -h "$WEBROOT" -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	printf 'User %s\nGroup %s\n' "$user" "$group" \
		> /etc/apache2/conf.d/zz-wordpress-user.conf
	echo "$user:$group" > /run/wordpress-owner
	einfo "Apache runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for MariaDB, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/wordpress-data

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

random_key() {
	head -c 4096 /dev/urandom \
		| tr -dc 'A-Za-z0-9!#%()*+,.:;<=>?@^_{|}~-' | head -c 64
}

write_wp_config() {
	local k
	{
		cat <<-PHP
		<?php
		// Generated on first boot by /etc/init.d/wordpress-prep.

		define( 'DB_NAME', '$DB_NAME' );
		define( 'DB_USER', '$DB_USER' );
		define( 'DB_PASSWORD', '$DB_PASSWORD' );
		define( 'DB_HOST', 'localhost:/run/mysqld/mysqld.sock' );
		define( 'DB_CHARSET', 'utf8mb4' );
		define( 'DB_COLLATE', '' );

		PHP
		for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
				AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
			printf "define( '%s', '%s' );\n" "$k" "$(random_key)"
		done
		cat <<-'PHP'

		$table_prefix = 'wp_';

		// Follow whatever host/port the site is reached at (e.g. QEMU hostfwd).
		if ( ! empty( $_SERVER['HTTP_HOST'] ) ) {
			$scheme = ( ! empty( $_SERVER['HTTPS'] ) && 'off' !== $_SERVER['HTTPS'] ) ? 'https' : 'http';
			define( 'WP_HOME', $scheme . '://' . $_SERVER['HTTP_HOST'] );
			define( 'WP_SITEURL', WP_HOME );
		}

		define( 'WP_ENVIRONMENT_TYPE', 'local' );
		define( 'WP_DEBUG', true );
		define( 'WP_DEBUG_LOG', true );
		define( 'WP_DEBUG_DISPLAY', false );
		define( 'FS_METHOD', 'direct' );

		if ( ! defined( 'ABSPATH' ) ) {
			define( 'ABSPATH', __DIR__ . '/' );
		}

		require_once ABSPATH . 'wp-settings.php';
		PHP
	} > "$WEBROOT"/wp-config.php
}

write_htaccess() {
	cat > "$WEBROOT"/.htaccess <<-'HTACCESS'
	# BEGIN WordPress
	<IfModule mod_rewrite.c>
	RewriteEngine On
	RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
	RewriteBase /
	RewriteRule ^index\.php$ - [L]
	RewriteCond %{REQUEST_FILENAME} !-f
	RewriteCond %{REQUEST_FILENAME} !-d
	RewriteRule . /index.php [L]
	</IfModule>
	# END WordPress
	HTACCESS
}

populate_webroot() {
	local owner src=/usr/share/wordpress/wordpress.tar.gz tmp

	owner=$(cat /run/wordpress-owner)

	if [ ! -f "$WEBROOT"/wp-load.php ]; then
		ebegin "Installing WordPress core files into $WEBROOT"
		tmp=$(mktemp -d)
		if [ ! -f "$src" ]; then
			# not bundled at build time, fall back to the network
			src="$tmp"/wordpress.tar.gz
			wget -q -O "$src" https://wordpress.org/latest.tar.gz
		fi
		# never overwrite files that already exist in the share
		tar -xzf "$src" -C "$tmp" \
			&& cp -Rn "$tmp"/wordpress/. "$WEBROOT"/
		eend $?
		rm -rf "$tmp"
	fi

	[ -f "$WEBROOT"/wp-config.php ] || write_wp_config
	[ -f "$WEBROOT"/.htaccess ] || write_htaccess

	# On a 9p share (security_model=none) this is a harmless no-op.
	chown -R "$owner" "$WEBROOT" 2>/dev/null || true
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot
}
EOF

# --- Service: create database and run the WordPress installer ---------------
makefile root:root 0755 "$tmp"/etc/init.d/wordpress-init <<'EOF'
#!/sbin/openrc-run

description="Create the WordPress database and install the site"

depend() {
	need mariadb wordpress-prep
	before apache2
}

. /etc/conf.d/wordpress

start() {
	local owner

	ebegin "Creating WordPress database"
	mariadb -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
	GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
	FLUSH PRIVILEGES;
	SQL
	eend $? || return 1

	ebegin "Installing WordPress site"
	owner=$(cat /run/wordpress-owner)
	WEBROOT="$WEBROOT" WP_URL="$WP_URL" WP_TITLE="$WP_TITLE" \
	WP_ADMIN_USER="$WP_ADMIN_USER" WP_ADMIN_PASSWORD="$WP_ADMIN_PASSWORD" \
	WP_ADMIN_EMAIL="$WP_ADMIN_EMAIL" \
		su -s /bin/sh "${owner%%:*}" -c "$PHP /usr/share/wordpress/install.php"
	eend $?
}
EOF

mkdir -p "$tmp"/usr/share/wordpress
makefile root:root 0644 "$tmp"/usr/share/wordpress/install.php <<'EOF'
<?php
// Non-interactive WordPress install, run by /etc/init.d/wordpress-init.

$url = parse_url( getenv( 'WP_URL' ) ?: 'http://localhost:8080' );
$_SERVER['HTTP_HOST']       = $url['host'] . ( isset( $url['port'] ) ? ':' . $url['port'] : '' );
$_SERVER['REQUEST_URI']     = '/';
$_SERVER['SERVER_PROTOCOL'] = 'HTTP/1.1';
if ( 'https' === ( $url['scheme'] ?? 'http' ) ) {
	$_SERVER['HTTPS'] = 'on';
}

define( 'WP_INSTALLING', true );
require getenv( 'WEBROOT' ) . '/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';

if ( is_blog_installed() ) {
	exit( 0 );
}

$result = wp_install(
	getenv( 'WP_TITLE' ),
	getenv( 'WP_ADMIN_USER' ),
	getenv( 'WP_ADMIN_EMAIL' ),
	true,
	'',
	wp_slash( getenv( 'WP_ADMIN_PASSWORD' ) )
);
if ( is_wp_error( $result ) ) {
	fwrite( STDERR, $result->get_error_message() . "\n" );
	exit( 1 );
}

update_option( 'permalink_structure', '/%postname%/' );
EOF

# --- Bundle WordPress so the first boot works offline -----------------------
if [ -n "$WP_TARBALL" ]; then
	cp "$WP_TARBALL" "$tmp"/usr/share/wordpress/wordpress.tar.gz
else
	case "$WP_VERSION" in
	latest) wp_url=https://wordpress.org/latest.tar.gz ;;
	*) wp_url=https://wordpress.org/wordpress-$WP_VERSION.tar.gz ;;
	esac
	if wget -q -O "$tmp"/usr/share/wordpress/wordpress.tar.gz "$wp_url" \
		&& sha1=$(wget -q -O - "$wp_url.sha1") \
		&& echo "$sha1  $tmp/usr/share/wordpress/wordpress.tar.gz" | sha1sum -c >/dev/null; then
		:
	else
		echo "WARNING: could not bundle WordPress, guest will download it on first boot" >&2
		rm -f "$tmp"/usr/share/wordpress/wordpress.tar.gz
	fi
fi

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd wordpress-prep mariadb wordpress-init apache2; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

#!/bin/sh -e
# genapkovl-lamp.sh - build the boot overlay (apkovl) for the "lamp" profile
# Installed by mkimg.lamp.sh via profile_apkovl

HOSTNAME="${1:-alpine-test}"

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

# --- Apache vhost / directory config for WordPress -------------------------
mkdir -p "$tmp"/etc/apache2/conf.d
cat > "$tmp"/etc/apache2/conf.d/wordpress.conf <<'EOF'
DirectoryIndex index.php index.html
<Directory "/var/www/localhost/htdocs">
    AllowOverride All
    Require all granted
</Directory>
EOF

# --- PHP tuning for WordPress ------------------------------------------------
mkdir -p "$tmp"/etc/php83/conf.d
cat > "$tmp"/etc/php83/conf.d/zzz-wordpress.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
EOF

# --- First-boot script: init MariaDB, create DB, fetch & configure WP ------
mkdir -p "$tmp"/etc/local.d
cat > "$tmp"/etc/local.d/wordpress-setup.start <<'STARTEOF'
#!/bin/sh
# Runs once at first boot. Idempotent via /var/lib/wordpress-setup.done
FLAG=/var/lib/wordpress-setup.done
[ -f "$FLAG" ] && exit 0

DB_NAME=wordpress
DB_USER=wordpress
DB_PASS=$(head -c 24 /dev/urandom | md5sum | cut -c1-16)
WEBROOT=/var/www/localhost/htdocs

if [ ! -d /var/lib/mysql/mysql ]; then
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql \
        > /var/log/mariadb-install.log 2>&1
fi

rc-service mariadb start
i=0
while ! mysqladmin ping >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -ge 30 ] && { echo "mariadb did not start" >&2; exit 1; }
    sleep 1
done

mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

if [ ! -f "$WEBROOT/wp-load.php" ]; then
    mkdir -p "$WEBROOT"
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/. "$WEBROOT"/
    rm -rf /tmp/wordpress /tmp/latest.tar.gz
fi

if [ ! -f "$WEBROOT/wp-config.php" ]; then
    cp "$WEBROOT/wp-config-sample.php" "$WEBROOT/wp-config.php"
    sed -i "s/database_name_here/${DB_NAME}/" "$WEBROOT/wp-config.php"
    sed -i "s/username_here/${DB_USER}/" "$WEBROOT/wp-config.php"
    sed -i "s/password_here/${DB_PASS}/" "$WEBROOT/wp-config.php"

    SALTS=$(wget -qO- https://api.wordpress.org/secret-key/1.1/salt/ || true)
    if [ -n "$SALTS" ]; then
        awk '/AUTH_KEY.*put your unique phrase here/{start=1} !start{print}' \
            "$WEBROOT/wp-config.php" > "$WEBROOT/wp-config.new"
        printf '%s\n' "$SALTS" >> "$WEBROOT/wp-config.new"
        awk 'BEGIN{p=0} /require_once ABSPATH/{p=1} p' \
            "$WEBROOT/wp-config.php" >> "$WEBROOT/wp-config.new"
        mv "$WEBROOT/wp-config.new" "$WEBROOT/wp-config.php"
    fi
fi

chown -R apache:apache "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;

{
    echo "WordPress DB name: ${DB_NAME}"
    echo "WordPress DB user: ${DB_USER}"
    echo "WordPress DB pass: ${DB_PASS}"
    echo "MariaDB root has NO password set - run 'mysql_secure_installation'."
} > /root/wordpress-credentials.txt
chmod 600 /root/wordpress-credentials.txt

touch "$FLAG"
STARTEOF
chmod +x "$tmp"/etc/local.d/wordpress-setup.start

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking local mariadb apache2 sshd; do
	rc_add "$svc" default
done

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

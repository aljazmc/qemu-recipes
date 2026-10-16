#!/bin/sh -e
# genapkovl-node.sh - build the boot overlay (apkovl) for the "node" profile
# Installed by mkimg.node.sh via apkovl
#
# The resulting VM boots straight into a running Node.js app backed by
# PostgreSQL 18 with a ready-to-use database. Nothing has to be installed or
# configured inside the guest.
#
# Host <-> guest sharing of the app root (/var/www/html) is done with
# virtio-9p. Start QEMU with e.g.:
#
#   mkdir -p ~/node-dev
#   qemu-img create -f qcow2 ~/node-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-node-edge-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:3000,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/node-dev",mount_tag=www,security_model=none,id=www \
#       -drive file="$HOME/node-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080.
#
# - An empty shared directory gets a starter app (server.js + package.json,
#   with the "postgres" client bundled so it works offline); existing files
#   are never touched.
# - The app is started with "npm start" (or server.js / index.js when there is
#   no start script) and restarted whenever a file in the shared directory
#   changes. node_modules and .git are not watched.
# - "npm install" runs automatically when node_modules is missing or older
#   than package.json (needs network). Install native modules from inside the
#   guest, the guest is musl based.
# - The app runs with the uid/gid that owns the shared directory on the host,
#   so files it writes stay editable on the host.
# - Without -virtfs the app root lives in RAM; without the extra virtio disk
#   the database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "nodedb") on first boot and
#   used for PostgreSQL data from then on.
# - App output: /var/log/node-app.log
#
# The app gets PORT, DATABASE_URL, PGHOST, PGPORT, PGDATABASE, PGUSER,
# PGPASSWORD and NODE_ENV in its environment.
#
# Build-time settings (environment variables):
#   DB_NAME              database created on boot          [app]
#   DB_USER              database user                     [app]
#   DB_PASSWORD          database password                 [app]
#   APP_PORT             port the app listens on           [3000]
#   POSTGRES_JS_VERSION  "postgres" npm package to bundle  [latest]
#
# They end up in /etc/conf.d/node in the guest.

HOSTNAME="${1:-node}"

: "${DB_NAME:=app}"
: "${DB_USER:=app}"
: "${DB_PASSWORD:=app}"
: "${APP_PORT:=3000}"
: "${POSTGRES_JS_VERSION:=latest}"

PG=postgresql18

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
e2fsprogs
nodejs
npm
openssh
$PG
$PG-client
$PG-openrc
postgresql-common-openrc
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/node.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the node-* services and the app ----------------------
# Readable by the app user: it is sourced by node-dev-run.
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0644 "$tmp"/etc/conf.d/node <<EOF
# Settings for /etc/init.d/node-prep, node-init, node-app and node-dev-run

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=www)
SHARE_TAG="www"
# filesystem label of the persistent PostgreSQL disk
DB_LABEL="nodedb"

DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"

# environment of the app
PORT="$APP_PORT"
NODE_ENV="development"
PGHOST="localhost"
PGPORT="5432"
PGDATABASE="\$DB_NAME"
PGUSER="\$DB_USER"
PGPASSWORD="\$DB_PASSWORD"
DATABASE_URL="postgres://\$DB_USER:\$DB_PASSWORD@localhost:5432/\$DB_NAME"
EOF

# Keep the PostgreSQL config next to the data, so it persists on the DB disk.
makefile root:root 0644 "$tmp"/etc/conf.d/postgresql <<'EOF'
pg_version="18"
data_dir="/var/lib/postgresql/18/data"
conf_dir="$data_dir"
initdb_opts="-E UTF-8 --locale-provider=icu --icu-locale=en-001-x-icu --data-checksums --auth-local=peer --auth-host=scram-sha-256"
EOF

# --- Service: mount share, prepare DB storage, populate app root -------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/node-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared app root and prepare PostgreSQL storage"

depend() {
	need localmount
	after modules
	before postgresql node-app
}

. /etc/conf.d/node

mount_share() {
	mountpoint -q "$WEBROOT" && return 0
	mkdir -p "$WEBROOT"
	ebegin "Mounting host share '$SHARE_TAG' on $WEBROOT"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$WEBROOT" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, app root is kept in RAM"
	fi
}

# Run the app as the owner of the shared directory so the host user and
# the app can both write to it.
setup_owner() {
	local uid= gid= user= group=

	if mountpoint -q "$WEBROOT"; then
		uid=$(stat -c %u "$WEBROOT")
		gid=$(stat -c %g "$WEBROOT")
	fi

	if [ -z "$uid" ] || [ "$uid" = 0 ]; then
		group=node-dev
		user=node-dev
		addgroup -S "$group" 2>/dev/null || true
		adduser -S -D -H -s /sbin/nologin -G "$group" "$user" 2>/dev/null || true
	else
		group=$(awk -F: -v id="$gid" '$3 == id { print $1; exit }' /etc/group)
		if [ -z "$group" ]; then
			group=node-dev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=node-dev
			adduser -D -H -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	# npm cache etc. must not end up in the shared directory
	mkdir -p /var/cache/node-dev
	chown "$user:$group" /var/cache/node-dev
	touch /var/log/node-app.log
	chown "$user:$group" /var/log/node-app.log

	echo "$user:$group" > /run/node-owner
	einfo "App runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for PostgreSQL, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/node-data

	dev=$(blkid -L "$DB_LABEL" 2>/dev/null) || dev=
	if [ -z "$dev" ]; then
		for d in /dev/vd?; do
			[ -b "$d" ] || continue
			n=${d#/dev/}
			ls -d /sys/block/"$n"/"$n"?* >/dev/null 2>&1 && continue
			[ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] && continue
			[ -n "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null)" ] && continue
			ebegin "Formatting blank disk $d for PostgreSQL data"
			mkfs.ext4 -q -L "$DB_LABEL" "$d"
			eend $? || return 1
			dev=$d
			break
		done
	fi

	mkdir -p /var/lib/postgresql
	if [ -n "$dev" ] && ! mountpoint -q /var/lib/postgresql; then
		ebegin "Mounting $dev as PostgreSQL storage"
		mkdir -p "$data"
		mount -t ext4 "$dev" "$data" \
			&& mkdir -p "$data"/postgresql \
			&& mount --bind "$data"/postgresql /var/lib/postgresql
		eend $?
	elif [ -z "$dev" ]; then
		ewarn "No persistent disk, PostgreSQL data is kept in RAM"
	fi
	# the cluster itself is created by the postgresql service (auto_setup)
	chown postgres:postgres /var/lib/postgresql
}

# Starter app, only written into an empty app root.
populate_webroot() {
	local tgz=/usr/share/node-dev/postgres.tgz ver=3.4.0 tmp

	[ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && return 0

	ebegin "Writing starter app into $WEBROOT"
	[ -f /usr/share/node-dev/postgres.version ] \
		&& ver=$(cat /usr/share/node-dev/postgres.version)

	cat > "$WEBROOT"/package.json <<-JSON
	{
	  "name": "node-starter",
	  "private": true,
	  "scripts": {
	    "start": "node server.js"
	  },
	  "dependencies": {
	    "postgres": "^$ver"
	  }
	}
	JSON

	cat > "$WEBROOT"/server.js <<-'JS'
	// Starter app generated by /etc/init.d/node-prep - replace freely.
	// Connection settings come from DATABASE_URL / PG* (see /etc/conf.d/node).
	const http = require('node:http');
	const postgres = require('postgres');

	const sql = postgres(process.env.DATABASE_URL);
	const port = Number(process.env.PORT) || 3000;

	const escape = (s) => String(s).replace(/[&<>"']/g,
	  (c) => `&#${c.charCodeAt(0)};`);

	http.createServer(async (req, res) => {
	  let db;
	  try {
	    const [row] = await sql`select version()`;
	    db = `connected, ${row.version}`;
	  } catch (err) {
	    db = `connection failed: ${err.message}`;
	  }
	  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
	  res.end(`<!doctype html>
	<title>Node is up</title>
	<h1>Node is up</h1>
	<p>Node ${escape(process.version)}, served from <code>${escape(__dirname)}</code></p>
	<p>PostgreSQL (<code>${escape(process.env.PGDATABASE)}</code> as <code>${escape(process.env.PGUSER)}</code>): ${escape(db)}</p>
	`);
	}).listen(port, () => console.log(`listening on :${port}`));
	JS

	if [ -f "$tgz" ]; then
		# bundled client, so the starter works without network
		tmp=$(mktemp -d)
		tar -xzf "$tgz" -C "$tmp" \
			&& mkdir -p "$WEBROOT"/node_modules \
			&& cp -R "$tmp"/package "$WEBROOT"/node_modules/postgres
		rm -rf "$tmp"
		# written last: node-dev-run only runs npm install when
		# package.json is newer than this file
		cat > "$WEBROOT"/node_modules/.package-lock.json <<-JSON
		{
		  "name": "node-starter",
		  "lockfileVersion": 3,
		  "requires": true,
		  "packages": {
		    "node_modules/postgres": {
		      "version": "$ver",
		      "license": "Unlicense"
		    }
		  }
		}
		JSON
	fi
	eend 0

	# On a 9p share (security_model=none) this is a harmless no-op.
	chown -R "$(cat /run/node-owner)" "$WEBROOT" 2>/dev/null || true
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot
}
EOF

# --- Service: create the application database --------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/node-init <<'EOF'
#!/sbin/openrc-run

description="Create the application database and user"

depend() {
	need postgresql node-prep
	before node-app
}

. /etc/conf.d/node

start() {
	ebegin "Creating database '$DB_NAME'"
	cd /tmp
	su -s /bin/sh postgres -c "psql -q -v ON_ERROR_STOP=1" <<-SQL
	SELECT 'CREATE ROLE "$DB_USER" LOGIN'
	  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER')\gexec
	ALTER ROLE "$DB_USER" WITH LOGIN PASSWORD '$DB_PASSWORD';
	SELECT 'CREATE DATABASE "$DB_NAME" OWNER "$DB_USER"'
	  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
	SQL
	eend $?
}
EOF

# --- Service: the app itself --------------------------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/node-app <<'EOF'
#!/sbin/openrc-run

description="Node.js app from the shared app root (auto-restarts on changes)"

supervisor=supervise-daemon
command=/usr/local/bin/node-dev-run
output_log=/var/log/node-app.log
error_log=/var/log/node-app.log
respawn_delay=2
respawn_max=0

depend() {
	need net node-prep node-init
	after postgresql
}

start_pre() {
	command_user=$(cat /run/node-owner)
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/node-dev-run <<'EOF'
#!/bin/sh
# node-dev-run - run the app in $WEBROOT and restart it whenever a file
# changes. Polls instead of using inotify, which does not see changes made
# on the host side of a 9p share.

. /etc/conf.d/node
export PORT NODE_ENV PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD DATABASE_URL
export HOME=/var/cache/node-dev
export npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false

cd "$WEBROOT" || exit 1

child=

snapshot() {
	find . \( -path ./node_modules -o -path ./.git \) -prune \
		-o -type f -exec stat -c '%Y %s %n' {} + 2>/dev/null | md5sum
}

stop_child() {
	[ -n "$child" ] || return 0
	# the app runs in its own session, take down the whole tree
	pkill -TERM -s "$child" 2>/dev/null
	wait "$child" 2>/dev/null
	child=
}

start_child() {
	if [ -f package.json ] && { [ ! -f node_modules/.package-lock.json ] \
			|| [ package.json -nt node_modules/.package-lock.json ]; }; then
		echo "node-dev-run: npm install"
		npm install || echo "node-dev-run: npm install failed"
	fi

	if [ -f package.json ] && npm pkg get scripts.start | grep -qv '^{}$'; then
		setsid npm start &
	elif [ -f server.js ]; then
		setsid node server.js &
	elif [ -f index.js ]; then
		setsid node index.js &
	else
		echo "node-dev-run: nothing to run in $WEBROOT (no start script, server.js or index.js)"
		return
	fi
	child=$!
}

trap 'stop_child; exit 0' TERM INT

last=$(snapshot)
start_child
while :; do
	sleep 1
	now=$(snapshot)
	if [ "$now" != "$last" ]; then
		last=$now
		echo "node-dev-run: change detected, restarting"
		stop_child
		start_child
	elif [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
		# exited or crashed: wait for the next change instead of looping
		wait "$child" 2>/dev/null
		echo "node-dev-run: app exited ($?), waiting for changes"
		child=
	fi
done
EOF

# --- Bundle the "postgres" client so the starter app works offline ----------
mkdir -p "$tmp"/usr/share/node-dev
if meta=$(wget -q -O - "https://registry.npmjs.org/postgres/$POSTGRES_JS_VERSION") \
	&& ver=$(echo "$meta" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n 1) \
	&& url=$(echo "$meta" | sed -n 's/.*"tarball":"\([^"]*\)".*/\1/p' | head -n 1) \
	&& sha1=$(echo "$meta" | sed -n 's/.*"shasum":"\([^"]*\)".*/\1/p' | head -n 1) \
	&& [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha1" ] \
	&& wget -q -O "$tmp"/usr/share/node-dev/postgres.tgz "$url" \
	&& echo "$sha1  $tmp/usr/share/node-dev/postgres.tgz" | sha1sum -c >/dev/null; then
	echo "$ver" > "$tmp"/usr/share/node-dev/postgres.version
else
	echo "WARNING: could not bundle the postgres npm package, the starter app will npm install it" >&2
	rm -f "$tmp"/usr/share/node-dev/postgres.tgz
fi

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd node-prep postgresql node-init node-app; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

#!/bin/sh -e
# genapkovl-django.sh - build the boot overlay (apkovl) for the "django" profile
# Installed by mkimg.django.sh via apkovl
#
# The resulting VM boots straight into a running Django project backed by
# PostgreSQL 18, migrated and with an admin user. Nothing has to be installed
# or configured inside the guest.
#
# Host <-> guest sharing of the project root (/var/www/html) is done with
# virtio-9p. Start QEMU with e.g.:
#
#   mkdir -p ~/django-dev
#   qemu-img create -f qcow2 ~/django-db.qcow2 4G     # optional, keeps the DB
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-django-v3.24-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:8000,hostfwd=tcp::2222-:22 \
#       -virtfs local,path="$HOME/django-dev",mount_tag=www,security_model=none,id=www \
#       -drive file="$HOME/django-db.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080 (admin: http://localhost:8080/admin).
#
# - An empty shared directory gets a new project ("django-admin startproject"
#   with Alpine's Django 5.2, so it works offline), set up for PostgreSQL.
#   Existing files are never touched, so it can hold your own project.
# - The project is run with "manage.py runserver", which reloads by itself
#   when a Python file changes. On every start "manage.py migrate" runs and
#   the admin user is created when it doesn't exist.
# - With a requirements.txt, the packages are pip installed (needs network)
#   into a virtualenv in the guest that also sees Alpine's Django and
#   psycopg. After changing requirements.txt run
#   "rc-service django-app restart" in the guest.
# - The app runs with the uid/gid that owns the shared directory on the host,
#   so files it writes stay editable on the host.
# - Without -virtfs the project lives in RAM; without the extra virtio disk
#   the database lives in RAM. Both are then lost on poweroff.
# - A blank virtio disk is formatted (ext4, label "djangodb") on first boot and
#   used for PostgreSQL data from then on.
# - App output: /var/log/django-app.log
#
# The app gets DATABASE_URL, PGHOST, PGPORT, PGDATABASE, PGUSER and
# PGPASSWORD in its environment.
#
# Build-time settings (environment variables):
#   DB_NAME                database created on boot           [app]
#   DB_USER                database user                      [app]
#   DB_PASSWORD            database password                  [app]
#   APP_PORT               port runserver listens on          [8000]
#   DJANGO_PROJECT         name of a new project              [mysite]
#   DJANGO_ADMIN_USER      admin login, empty = no admin      [admin]
#   DJANGO_ADMIN_PASSWORD  admin password                     [admin]
#   DJANGO_ADMIN_EMAIL     admin e-mail                       [admin@example.com]
#
# They end up in /etc/conf.d/django in the guest.

HOSTNAME="${1:-django}"

: "${DB_NAME:=app}"
: "${DB_USER:=app}"
: "${DB_PASSWORD:=app}"
: "${APP_PORT:=8000}"
: "${DJANGO_PROJECT:=mysite}"
: "${DJANGO_ADMIN_USER=admin}"
: "${DJANGO_ADMIN_PASSWORD:=admin}"
: "${DJANGO_ADMIN_EMAIL:=admin@example.com}"

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
openssh
openssh-server-common-openrc
$PG
$PG-client
$PG-openrc
postgresql-common-openrc
py3-django
py3-pip
py3-psycopg
python3
tzdata
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/django.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the django-* services and the app --------------------
# Readable by the app user: it is sourced by django-dev-run.
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0644 "$tmp"/etc/conf.d/django <<EOF
# Settings for /etc/init.d/django-prep, django-init, django-app and django-dev-run

WEBROOT="/var/www/html"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=www)
SHARE_TAG="www"
# filesystem label of the persistent PostgreSQL disk
DB_LABEL="djangodb"

DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"

PORT="$APP_PORT"
DJANGO_PROJECT="$DJANGO_PROJECT"
# admin user created by django-dev-run when missing; empty = none
DJANGO_ADMIN_USER="$DJANGO_ADMIN_USER"
DJANGO_ADMIN_PASSWORD="$DJANGO_ADMIN_PASSWORD"
DJANGO_ADMIN_EMAIL="$DJANGO_ADMIN_EMAIL"

# environment of the app
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

# --- Service: mount share, prepare DB storage, populate project root --------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/django-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared project root and prepare PostgreSQL storage"

depend() {
	need localmount
	after modules
	before postgresql django-app
}

. /etc/conf.d/django

mount_share() {
	mountpoint -q "$WEBROOT" && return 0
	mkdir -p "$WEBROOT"
	ebegin "Mounting host share '$SHARE_TAG' on $WEBROOT"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$WEBROOT" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, project root is kept in RAM"
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
		group=django-dev
		user=django-dev
		addgroup -S "$group" 2>/dev/null || true
		adduser -S -D -H -s /sbin/nologin -G "$group" "$user" 2>/dev/null || true
	else
		group=$(awk -F: -v id="$gid" '$3 == id { print $1; exit }' /etc/group)
		if [ -z "$group" ]; then
			group=django-dev
			addgroup -g "$gid" "$group"
		fi
		user=$(awk -F: -v id="$uid" '$3 == id { print $1; exit }' /etc/passwd)
		if [ -z "$user" ]; then
			user=django-dev
			adduser -D -H -s /sbin/nologin -G "$group" -u "$uid" "$user"
		fi
	fi

	# pip cache and the virtualenv must not end up in the shared directory
	mkdir -p /var/cache/django-dev
	chown "$user:$group" /var/cache/django-dev
	touch /var/log/django-app.log
	chown "$user:$group" /var/log/django-app.log

	echo "$user:$group" > /run/django-owner
	einfo "App runs as $user:$group"
}

# Use a virtio disk labelled $DB_LABEL for PostgreSQL, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_db_storage() {
	local dev= d= n= data=/var/lib/django-data

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

# New project, only created in an empty project root.
populate_webroot() {
	local settings="$WEBROOT/$DJANGO_PROJECT/settings.py"

	[ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && return 0

	ebegin "Creating Django project '$DJANGO_PROJECT' in $WEBROOT"
	django-admin startproject "$DJANGO_PROJECT" "$WEBROOT" \
		&& cat >> "$settings" <<-'PY'


	# --- Added by /etc/init.d/django-prep for the development VM -----------
	# The database settings come from the environment the VM gives the app
	# (PGHOST, PGDATABASE, ... in /etc/conf.d/django).
	import os

	DEBUG = True
	ALLOWED_HOSTS = ['*']

	DATABASES = {
	    'default': {
	        'ENGINE': 'django.db.backends.postgresql',
	        'NAME': os.environ.get('PGDATABASE', 'app'),
	        'USER': os.environ.get('PGUSER', 'app'),
	        'PASSWORD': os.environ.get('PGPASSWORD', ''),
	        'HOST': os.environ.get('PGHOST', 'localhost'),
	        'PORT': os.environ.get('PGPORT', '5432'),
	    }
	}

	STATIC_ROOT = BASE_DIR / 'staticfiles'
	PY
	eend $?

	# On a 9p share (security_model=none) this is a harmless no-op.
	chown -R "$(cat /run/django-owner)" "$WEBROOT" 2>/dev/null || true
}

start() {
	mount_share
	setup_owner
	prepare_db_storage || return 1
	populate_webroot
}
EOF

# --- Service: create the application database --------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/django-init <<'EOF'
#!/sbin/openrc-run

description="Create the application database and user"

depend() {
	need postgresql django-prep
	before django-app
}

. /etc/conf.d/django

start() {
	ebegin "Creating database '$DB_NAME'"
	cd /tmp
	su -s /bin/sh postgres -c "psql -q -v ON_ERROR_STOP=1" <<-SQL
	SELECT 'CREATE ROLE "$DB_USER" LOGIN'
	  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER')\gexec
	ALTER ROLE "$DB_USER" WITH LOGIN PASSWORD '$DB_PASSWORD' CREATEDB;
	SELECT 'CREATE DATABASE "$DB_NAME" OWNER "$DB_USER"'
	  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
	SQL
	eend $?
}
EOF

# --- Service: the app itself --------------------------------------------------
makefile root:root 0755 "$tmp"/etc/init.d/django-app <<'EOF'
#!/sbin/openrc-run

description="Django project from the shared project root (runserver, auto-reloads)"

supervisor=supervise-daemon
command=/usr/local/bin/django-dev-run
output_log=/var/log/django-app.log
error_log=/var/log/django-app.log
respawn_delay=5
respawn_max=0

depend() {
	need net django-prep django-init
	after postgresql
}

start_pre() {
	command_user=$(cat /run/django-owner)
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/django-dev-run <<'EOF'
#!/bin/sh
# django-dev-run - migrate the project in $WEBROOT, make sure the admin user
# exists and run "manage.py runserver". runserver's own reloader polls the
# files (StatReloader), which also sees changes made on the host side of a
# 9p share.

. /etc/conf.d/django
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD DATABASE_URL
export DJANGO_ADMIN_USER DJANGO_ADMIN_PASSWORD DJANGO_ADMIN_EMAIL
export HOME=/var/cache/django-dev
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1

cd "$WEBROOT" || exit 1

py=python3
if [ -f requirements.txt ]; then
	venv=/var/cache/django-dev/venv
	if [ ! -x "$venv"/bin/python ] || [ requirements.txt -nt "$venv"/.installed ]; then
		echo "django-dev-run: pip install -r requirements.txt"
		python3 -m venv --system-site-packages --without-pip "$venv" \
			&& "$venv"/bin/python -m pip install -q -r requirements.txt \
			&& touch "$venv"/.installed \
			|| echo "django-dev-run: pip install failed"
	fi
	[ -x "$venv"/bin/python ] && py=$venv/bin/python
fi

if [ ! -f manage.py ]; then
	echo "django-dev-run: no manage.py in $WEBROOT, waiting for one"
	while [ ! -f manage.py ]; do sleep 2; done
fi

"$py" manage.py migrate --noinput || echo "django-dev-run: migrate failed"

if [ -n "$DJANGO_ADMIN_USER" ]; then
	"$py" manage.py shell -c '
import os
from django.contrib.auth import get_user_model
User = get_user_model()
name = os.environ["DJANGO_ADMIN_USER"]
if not User._default_manager.filter(**{User.USERNAME_FIELD: name}).exists():
    User._default_manager.create_superuser(
        name, os.environ["DJANGO_ADMIN_EMAIL"], os.environ["DJANGO_ADMIN_PASSWORD"])
    print("django-dev-run: created admin user", name)
' || echo "django-dev-run: could not create the admin user"
fi

exec "$py" manage.py runserver "0.0.0.0:${PORT:-8000}"
EOF

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd django-prep postgresql django-init django-app; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

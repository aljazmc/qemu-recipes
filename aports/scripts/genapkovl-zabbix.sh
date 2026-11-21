#!/bin/sh -e
# genapkovl-zabbix.sh - build the boot overlay (apkovl) for the "zabbix" profile
# Installed by mkimg.zabbix.sh via apkovl
#
# The resulting VM boots straight into Zabbix 7.4 (server, web frontend on
# nginx + PHP 8.3, PostgreSQL 18) and Grafana with the Zabbix plugin, and
# monitors every VM from this repository it finds on the monitoring network
# (see monitoring-agent.sh): each one becomes a Zabbix host (group
# "qemu-recipes VMs", template "Linux by Zabbix agent", tag profile=...) that
# is checked through its zabbix_agent2. VMs that come up later are added
# within ~30s, and a host follows its VM when the VM's address changes.
# Nothing has to be installed or configured inside the guest.
#
# Start QEMU with e.g.:
#
#   mkdir -p ~/zabbix-dev
#   qemu-img create -f qcow2 ~/zabbix-data.qcow2 8G   # optional, keeps the data
#   qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
#       -cdrom iso/alpine-v3.24-zabbix-x86_64.iso \
#       -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::3000-:3000,hostfwd=tcp::2222-:22 \
#       -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
#       -virtfs local,path="$HOME/zabbix-dev",mount_tag=zabbix,security_model=none,id=zabbix \
#       -drive file="$HOME/zabbix-data.qcow2",if=virtio,format=qcow2
#
# and open http://localhost:8080 (Zabbix, Admin / zabbix) or
# http://localhost:3000 (Grafana, admin / admin).
#
# - The shared directory (/srv/zabbix) holds dashboards/*.json, Grafana
#   dashboards (folder "Shared", re-read every 10s).
# - Grafana has Zabbix as its default data source and the dashboard
#   "VMs (Zabbix)" (folder qemu-recipes).
# - The Zabbix database is created on first boot (takes about a minute).
# - A blank virtio disk is formatted (ext4, label "zabbixdb") on first boot
#   and holds the PostgreSQL and Grafana data from then on. Without it they
#   live in RAM and are lost on poweroff.
#
# Build-time settings (environment variables):
#   ZABBIX_ADMIN_PASSWORD          password of the Zabbix user Admin   [zabbix]
#   GRAFANA_ADMIN_USER             Grafana admin login                 [admin]
#   GRAFANA_ADMIN_PASSWORD         Grafana admin password              [admin]
#   GRAFANA_ZABBIX_PLUGIN_VERSION  Grafana Zabbix plugin to bundle     [latest]

HOSTNAME="${1:-zabbix}"

: "${ZABBIX_ADMIN_PASSWORD:=zabbix}"

PHP=php83
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

# Agents and the monitoring network, shared by all profiles
. "$(dirname "$0")"/monitoring-agent.sh
. "$(dirname "$0")"/monitoring-grafana.sh

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
nginx
nginx-openrc
openssh
openssh-server-common-openrc
$PHP
$PHP-fpm
$PHP-pgsql
$PG
$PG-client
$PG-openrc
postgresql-common-openrc
zabbix-openrc
zabbix-pgsql
zabbix-setup
zabbix-webif
EOF

# --- 9p (host shared folder) kernel modules ----------------------------------
mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/zabbix.conf <<EOF
9pnet_virtio
9p
EOF

# --- Settings shared by the zabbix-* services --------------------------------
mkdir -p "$tmp"/etc/conf.d
makefile root:root 0600 "$tmp"/etc/conf.d/zabbix-dev <<EOF
# Settings for /etc/init.d/zabbix-prep, zabbix-init and zabbix-discover

SHARE="/srv/zabbix"
# virtio-9p mount_tag of the host shared folder (-virtfs ...,mount_tag=zabbix)
SHARE_TAG="zabbix"
# filesystem label of the persistent data disk
DATA_LABEL="zabbixdb"

DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASSWORD="zabbix"

ZABBIX_ADMIN_PASSWORD="$ZABBIX_ADMIN_PASSWORD"
# discovered VMs become hosts in this group, linked to this template
ZABBIX_HOST_GROUP="qemu-recipes VMs"
ZABBIX_TEMPLATE="Linux by Zabbix agent"

PHP="$PHP"
EOF

# Keep the PostgreSQL config next to the data, so it persists on the data disk.
makefile root:root 0644 "$tmp"/etc/conf.d/postgresql <<'EOF'
pg_version="18"
data_dir="/var/lib/postgresql/18/data"
conf_dir="$data_dir"
initdb_opts="-E UTF-8 --locale-provider=icu --icu-locale=en-001-x-icu --data-checksums --auth-local=peer --auth-host=scram-sha-256"
EOF

# zabbix-server: start only once the database exists
makefile root:root 0644 "$tmp"/etc/conf.d/zabbix-server <<'EOF'
pidfile="/var/run/zabbix/zabbix_server.pid"
command="/usr/sbin/zabbix_server"
rc_need="zabbix-init"
EOF

# --- Zabbix server --------------------------------------------------------------
mkdir -p "$tmp"/etc/zabbix
makefile root:root 0644 "$tmp"/etc/zabbix/zabbix_server.conf <<'EOF'
# Zabbix server for qemu-recipes (see /etc/conf.d/zabbix-dev)
LogType=file
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=1
PidFile=/var/run/zabbix/zabbix_server.pid
SocketDir=/var/run/zabbix
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=zabbix
Timeout=4
LogSlowQueries=3000
StatsAllowedIP=127.0.0.1
EnableGlobalScripts=0
# small VM: smaller caches than the defaults
CacheSize=32M
HistoryCacheSize=16M
HistoryIndexCacheSize=4M
TrendCacheSize=4M
ValueCacheSize=16M
EOF

# --- Frontend: nginx + PHP-FPM -----------------------------------------------------
mkdir -p "$tmp"/usr/share/webapps/zabbix/conf
makefile root:root 0644 "$tmp"/usr/share/webapps/zabbix/conf/zabbix.conf.php <<'EOF'
<?php
// Written by qemu-recipes (see /etc/conf.d/zabbix-dev): the frontend is
// configured already, so the setup wizard is skipped.
$DB['TYPE']				= 'POSTGRESQL';
$DB['SERVER']			= 'localhost';
$DB['PORT']				= '0';
$DB['DATABASE']			= 'zabbix';
$DB['USER']				= 'zabbix';
$DB['PASSWORD']			= 'zabbix';
$DB['SCHEMA']			= '';
$DB['ENCRYPTION']		= false;
$DB['KEY_FILE']			= '';
$DB['CERT_FILE']		= '';
$DB['CA_FILE']			= '';
$DB['VERIFY_HOST']		= true;
$DB['CIPHER_LIST']		= '';
$DB['VAULT']			= '';
$DB['VAULT_URL']		= '';
$DB['VAULT_PREFIX']		= '';
$DB['VAULT_DB_PATH']	= '';
$DB['VAULT_TOKEN']		= '';
$DB['VAULT_CERT_FILE']	= '';
$DB['VAULT_KEY_FILE']	= '';
$DB['DOUBLE_IEEE754']	= true;

$ZBX_SERVER_NAME		= 'qemu-recipes';
$IMAGE_FORMAT_DEFAULT	= IMAGE_FORMAT_PNG;
EOF

mkdir -p "$tmp"/etc/nginx/http.d
makefile root:root 0644 "$tmp"/etc/nginx/http.d/default.conf <<'EOF'
# Zabbix frontend
server {
	listen 80 default_server;
	listen [::]:80 default_server;
	root /usr/share/webapps/zabbix;
	index index.php;
	client_max_body_size 16M;

	location ~ ^/(conf|app|include|local|locale|vendor)/ {
		return 404;
	}
	location / {
		try_files $uri $uri/ =404;
	}
	location ~ \.php$ {
		try_files $uri =404;
		fastcgi_pass 127.0.0.1:9000;
		fastcgi_index index.php;
		fastcgi_read_timeout 300;
		include fastcgi.conf;
	}
}
EOF

mkdir -p "$tmp"/etc/$PHP/conf.d
makefile root:root 0644 "$tmp"/etc/$PHP/conf.d/zzz-zabbix.ini <<'EOF'
; Zabbix frontend requirements
memory_limit = 256M
post_max_size = 16M
upload_max_filesize = 2M
max_execution_time = 300
max_input_time = 300
date.timezone = UTC
EOF

# --- Grafana with the Zabbix plugin ---------------------------------------------------
grafana_setup /srv/zabbix/dashboards
grafana_zabbix_plugin
makefile root:root 0644 "$tmp"/etc/grafana/provisioning/datasources/zabbix.yaml <<EOF
apiVersion: 1
datasources:
  - name: Zabbix
    uid: zabbix
    type: alexanderzobnin-zabbix-datasource
    access: proxy
    url: http://localhost/api_jsonrpc.php
    isDefault: true
    jsonData:
      username: Admin
      trends: true
      trendsFrom: 7d
      trendsRange: 4d
      cacheTTL: 1h
      timeout: 30
    secureJsonData:
      password: $ZABBIX_ADMIN_PASSWORD
EOF

# --- Service: mount share, prepare data storage ------------------------------
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/zabbix-prep <<'EOF'
#!/sbin/openrc-run

description="Mount the shared directory and prepare PostgreSQL/Grafana storage"

depend() {
	need localmount
	after modules
	before postgresql grafana
}

. /etc/conf.d/zabbix-dev

mount_share() {
	mountpoint -q "$SHARE" && return 0
	mkdir -p "$SHARE"
	ebegin "Mounting host share '$SHARE_TAG' on $SHARE"
	if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 \
			"$SHARE_TAG" "$SHARE" 2>/dev/null; then
		eend 0
	else
		eend 1 "no share found, $SHARE is kept in RAM"
	fi
}

# Use a virtio disk labelled $DATA_LABEL for the data, formatting the first
# blank (no filesystem, no partitions) virtio disk on first boot.
prepare_storage() {
	local dev= d= n= data=/var/lib/monitoring-data

	dev=$(blkid -L "$DATA_LABEL" 2>/dev/null) || dev=
	if [ -z "$dev" ]; then
		for d in /dev/vd?; do
			[ -b "$d" ] || continue
			n=${d#/dev/}
			ls -d /sys/block/"$n"/"$n"?* >/dev/null 2>&1 && continue
			[ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] && continue
			[ -n "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null)" ] && continue
			ebegin "Formatting blank disk $d for PostgreSQL and Grafana data"
			mkfs.ext4 -q -L "$DATA_LABEL" "$d"
			eend $? || return 1
			dev=$d
			break
		done
	fi

	mkdir -p /var/lib/postgresql /var/lib/grafana
	if [ -n "$dev" ] && ! mountpoint -q /var/lib/postgresql; then
		ebegin "Mounting $dev as PostgreSQL and Grafana storage"
		mkdir -p "$data"
		mount -t ext4 "$dev" "$data" \
			&& mkdir -p "$data"/postgresql "$data"/grafana \
			&& mount --bind "$data"/postgresql /var/lib/postgresql \
			&& mount --bind "$data"/grafana /var/lib/grafana
		eend $?
	elif [ -z "$dev" ]; then
		ewarn "No persistent disk, PostgreSQL and Grafana data are kept in RAM"
	fi
	# the cluster itself is created by the postgresql service (auto_setup)
	chown postgres:postgres /var/lib/postgresql
	mkdir -p /var/lib/grafana/data
	chown -R grafana:grafana /var/lib/grafana
}

start() {
	mount_share
	prepare_storage || return 1
	mkdir -p "$SHARE"/dashboards /var/log/zabbix
	chown zabbix:zabbix /var/log/zabbix
}
EOF

# --- Service: create and fill the Zabbix database ----------------------------
makefile root:root 0755 "$tmp"/etc/init.d/zabbix-init <<'EOF'
#!/sbin/openrc-run

description="Create the Zabbix database on first boot"

depend() {
	need postgresql zabbix-prep
	before zabbix-server php-fpm83 nginx
}

. /etc/conf.d/zabbix-dev

start() {
	local sql=/usr/share/zabbix/database/postgresql f hash rc=0

	ebegin "Creating database '$DB_NAME'"
	cd /tmp
	su -s /bin/sh postgres -c "psql -q -v ON_ERROR_STOP=1" <<-SQL
	SELECT 'CREATE ROLE "$DB_USER" LOGIN'
	  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER')\gexec
	ALTER ROLE "$DB_USER" WITH LOGIN PASSWORD '$DB_PASSWORD';
	SELECT 'CREATE DATABASE "$DB_NAME" OWNER "$DB_USER"'
	  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
	SQL
	eend $? || return 1

	export PGPASSWORD="$DB_PASSWORD"
	set -- psql -q -v ON_ERROR_STOP=1 -h localhost -U "$DB_USER" -d "$DB_NAME"
	[ "$("$@" -tA -c "SELECT to_regclass('public.users') IS NOT NULL")" = t ] \
		&& return 0

	ebegin "Importing the Zabbix schema and data (takes a minute)"
	for f in schema.sql images.sql data.sql; do
		"$@" -f "$sql/$f" >> /var/log/zabbix-init.log 2>&1 || { rc=1; break; }
	done
	eend $rc "import failed, see /var/log/zabbix-init.log" || return 1

	# Admin's password is a bcrypt hash
	hash=$(P="$ZABBIX_ADMIN_PASSWORD" $PHP -r 'echo password_hash(getenv("P"), PASSWORD_BCRYPT);')
	"$@" -c "UPDATE users SET passwd = '$hash' WHERE username = 'Admin'"
}
EOF

# --- Service: add the VMs on the monitoring network as Zabbix hosts ----------
makefile root:root 0755 "$tmp"/etc/init.d/zabbix-discover <<'EOF'
#!/sbin/openrc-run

description="Add the qemu-recipes VMs found on the monitoring network to Zabbix"

supervisor=supervise-daemon
command=/usr/local/bin/zabbix-discover
output_log=/var/log/zabbix-discover.log
error_log=/var/log/zabbix-discover.log
respawn_delay=5
respawn_max=0

depend() {
	need zabbix-server avahi-daemon nginx php-fpm83
}
EOF

mkdir -p "$tmp"/usr/local/bin
makefile root:root 0755 "$tmp"/usr/local/bin/zabbix-discover <<'EOF'
#!/bin/sh
# zabbix-discover - every 30s, make sure every VM on the monitoring network
# is a Zabbix host (see /usr/share/qemu-recipes/zabbix-discover.php).

. /etc/conf.d/zabbix-dev
export ZABBIX_ADMIN_PASSWORD ZABBIX_HOST_GROUP ZABBIX_TEMPLATE
export ZABBIX_API=http://127.0.0.1/api_jsonrpc.php

while :; do
	$PHP /usr/share/qemu-recipes/zabbix-discover.php
	sleep 30
done
EOF

makefile root:root 0644 "$tmp"/usr/share/qemu-recipes/zabbix-discover.php <<'EOF'
<?php
// Add the qemu-recipes VMs on the monitoring network as Zabbix hosts (agent
// interface, group ZABBIX_HOST_GROUP, template ZABBIX_TEMPLATE) and keep their
// address up to date. Run by /usr/local/bin/zabbix-discover.

$token = null;

function api(string $method, array $params) {
	global $token;
	$headers = "Content-Type: application/json-rpc\r\n";
	if ($token !== null) {
		$headers .= "Authorization: Bearer $token\r\n";
	}
	$body = json_encode(['jsonrpc' => '2.0', 'method' => $method,
		'params' => $params, 'id' => 1]);
	$res = @file_get_contents(getenv('ZABBIX_API'), false, stream_context_create(
		['http' => ['method' => 'POST', 'header' => $headers, 'content' => $body,
			'timeout' => 20, 'ignore_errors' => true]]));
	$res = $res === false ? null : json_decode($res, true);
	if (!is_array($res) || isset($res['error']) || !array_key_exists('result', $res)) {
		$err = $res['error']['data'] ?? $res['error']['message'] ?? 'no answer';
		throw new RuntimeException("$method: $err");
	}
	return $res['result'];
}

function peers(): array {
	$own = [];
	foreach (explode("\n", (string) shell_exec('ip -4 -o addr show')) as $line) {
		if (preg_match('/inet ([0-9.]+)\//', $line, $m)) {
			$own[$m[1]] = true;
		}
	}
	$peers = [];
	foreach (explode("\n", (string) shell_exec('qemu-recipes-peers')) as $line) {
		$f = preg_split('/\s+/', trim($line));
		if (count($f) < 3 || isset($own[$f[1]])) {
			continue;   // this VM is the host "Zabbix server" already
		}
		$txt = [];
		foreach (array_slice($f, 2) as $kv) {
			[$k, $v] = array_pad(explode('=', $kv, 2), 2, '');
			$txt[$k] = $v;
		}
		if (isset($txt['zabbix_agent'])) {
			$peers[$f[0]] = ['ip' => $f[1], 'port' => $txt['zabbix_agent'],
				'profile' => $txt['profile'] ?? ''];
		}
	}
	return $peers;
}

$peers = peers();
if (!$peers) {
	exit(0);
}

try {
	$token = api('user.login', ['username' => 'Admin',
		'password' => getenv('ZABBIX_ADMIN_PASSWORD')]);

	$tpl = api('template.get', ['output' => ['templateid'],
		'filter' => ['host' => [getenv('ZABBIX_TEMPLATE')]]]);
	if (!$tpl) {
		throw new RuntimeException('template "' . getenv('ZABBIX_TEMPLATE') . '" not found');
	}
	$tplid = $tpl[0]['templateid'];

	$group = getenv('ZABBIX_HOST_GROUP');
	$grp = api('hostgroup.get', ['output' => ['groupid'], 'filter' => ['name' => [$group]]]);
	$grpid = $grp ? $grp[0]['groupid'] : api('hostgroup.create', ['name' => $group])['groupids'][0];

	foreach ($peers as $name => $p) {
		$host = api('host.get', ['output' => ['hostid'], 'filter' => ['host' => [$name]],
			'selectInterfaces' => ['interfaceid', 'ip', 'port', 'type', 'main']]);
		if (!$host) {
			api('host.create', [
				'host' => $name,
				'groups' => [['groupid' => $grpid]],
				'templates' => [['templateid' => $tplid]],
				'interfaces' => [['type' => 1, 'main' => 1, 'useip' => 1,
					'ip' => $p['ip'], 'dns' => '', 'port' => $p['port']]],
				'tags' => [['tag' => 'profile', 'value' => $p['profile']],
					['tag' => 'source', 'value' => 'qemu-recipes']],
			]);
			echo "zabbix-discover: added host $name ({$p['profile']}, {$p['ip']})\n";
			continue;
		}
		foreach ($host[0]['interfaces'] as $if) {
			if ($if['type'] == 1 && $if['main'] == 1
					&& ($if['ip'] !== $p['ip'] || $if['port'] !== $p['port'])) {
				api('hostinterface.update', ['interfaceid' => $if['interfaceid'],
					'ip' => $p['ip'], 'port' => $p['port']]);
				echo "zabbix-discover: host $name moved to {$p['ip']}\n";
			}
		}
	}
} catch (RuntimeException $e) {
	// the frontend or server may still be starting: try again next round
	echo 'zabbix-discover: ', $e->getMessage(), "\n";
} finally {
	if ($token !== null) {
		try { api('user.logout', []); } catch (RuntimeException $e) {}
	}
}
EOF

# --- Monitoring agents (see monitoring-agent.sh) ---------------------------
monitoring_agent zabbix zabbix_api=80 grafana=3000
monitoring_peers_tool

# --- Enable services ---------------------------------------------------------
for svc in devfs dmesg mdev hwdrivers modloop; do
	rc_add "$svc" sysinit
done
for svc in hwclock modules sysctl hostname bootmisc syslog; do
	rc_add "$svc" boot
done
for svc in networking sshd zabbix-prep postgresql zabbix-init zabbix-server \
		php-fpm83 nginx zabbix-discover; do
	rc_add "$svc" default
done
for svc in mount-ro killprocs savecache; do
	rc_add "$svc" shutdown
done

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"

# qemu-recipes

[![ShellCheck](https://github.com/aljazmc/qemu-recipes/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/aljazmc/qemu-recipes/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Alpine Linux 3.24](https://img.shields.io/badge/Alpine%20Linux-3.24-0d597f?logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![QEMU](https://img.shields.io/badge/QEMU-KVM-ff6600?logo=qemu&logoColor=white)](https://www.qemu.org/)
[![Profiles](https://img.shields.io/badge/profiles-11-0a7bbb)](#profiles)
[![Docker](https://img.shields.io/badge/built%20in-aljazmc%2Fimage--spinner-2496ed?logo=docker&logoColor=white)](https://hub.docker.com/r/aljazmc/image-spinner)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-fe5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org/)

Ready-to-boot development VMs as custom Alpine Linux ISOs. Each of the 11
profiles boots straight into its stack, from Django and Laravel to an X11
desktop and a monitoring trio of Prometheus, Zabbix and Grafana, with nothing
to install or configure inside the guest.

## Features

- **Boot and work.** Every ISO starts its stack on boot: web stacks with
  their database, a desktop over VNC and noVNC, or monitoring.
- **Edit on the host.** A host directory is shared with the VM over
  virtio-9p, with services running as the uid that owns it, so files stay
  editable on both sides.
- **Persistent data.** The first blank virtio disk is formatted as ext4 on
  first boot and holds the database from then on.
- **Monitoring that finds itself.** The `prometheus`, `zabbix` and `grafana`
  VMs discover the other VMs on a shared network and monitor them on their
  own.
- **Tested boots.** `tests/smoke-test.sh` boots every ISO headless and checks
  the login prompt, SSH, the stack's page with its database and the
  ownership of shared files.
- **Built in a container.** The ISOs are built in the
  [`aljazmc/image-spinner`](https://hub.docker.com/r/aljazmc/image-spinner)
  image, so the host needs only Docker and QEMU.

## Quick start

```sh
git clone https://github.com/aljazmc/qemu-recipes.git
cd qemu-recipes
./project.sh start
```

This clones `aports` on first run and builds the profile named in the
`start()` function of `project.sh` into `iso/`; see [Build](#build) for other
profiles and [Run](#run) to boot it.

## Profiles

Ready-to-boot Alpine Linux (3.24 stable, x86_64) ISO images for QEMU development VMs.
Each image starts its stack on boot with no installation or configuration
inside the guest, and shares a host directory with the VM over virtio-9p, so
you can edit files on the host and see the result in the VM right away.
The `prometheus`, `zabbix` and `grafana` VMs find the other VMs on a shared
[monitoring network](#monitoring-network) and monitor them on their own.

| Profile     | What boots                                    | Shared host dir is | Open on the host                          |
|-------------|-----------------------------------------------|--------------------|-------------------------------------------|
| `django`    | Django 5.2 (runserver), PostgreSQL 18         | `/var/www/html`    | <http://localhost:8080>                   |
| `drupal`    | Apache, PHP 8.4, MariaDB, installed Drupal    | `/var/www/html`    | <http://localhost:8080>                   |
| `grafana`   | Grafana, every prometheus/zabbix VM found as a data source | `/srv/grafana` | <http://localhost:3000> |
| `joomla`    | Apache, PHP 8.4, MariaDB, installed Joomla    | `/var/www/html`    | <http://localhost:8080>                   |
| `lamp`      | Apache, PHP 8.4, MariaDB                      | `/var/www/html`    | <http://localhost:8080>                   |
| `laravel`   | lighttpd, PHP 8.5 (FPM), MariaDB, Composer    | `/var/www/html`    | <http://localhost:8080>                   |
| `node`      | Node.js 24, PostgreSQL 18                     | `/var/www/html`    | <http://localhost:8080>                   |
| `prometheus` | Prometheus scraping every VM found, Grafana | `/srv/prometheus` | <http://localhost:3000> (Grafana), <http://localhost:9090> |
| `wordpress` | Apache, PHP 8.4, MariaDB, installed WordPress | `/var/www/html`    | <http://localhost:8080>                   |
| `x11`       | X11 desktop (openbox) over VNC / noVNC        | `/home/alpine`     | <http://localhost:6080/vnc.html?autoconnect=1&resize=remote> or `vncviewer localhost:5900` |
| `zabbix`    | Zabbix monitoring every VM found, Grafana     | `/srv/zabbix`      | <http://localhost:8080> (Zabbix), <http://localhost:3000> (Grafana) |

Each profile is a pair of scripts in `aports/scripts/`: `mkimg.<profile>.sh`
lists the packages put on the ISO, and `genapkovl-<profile>.sh` generates the
boot overlay (config, services) that sets everything up. All profiles share
`monitoring-agent.sh` (monitoring network, agents); the monitoring profiles
also share `monitoring-grafana.sh` (Grafana setup and dashboards).

## Requirements

- Docker with the compose plugin (the image is built in the
  [`aljazmc/image-spinner`](https://hub.docker.com/r/aljazmc/image-spinner) container)
- QEMU (`qemu-system-x86_64`, `qemu-img`); KVM is recommended
- Internet access while building

## Build

```sh
./project.sh start
```

This clones `aports` on first run and builds the profile named in the
`start()` function of `project.sh` (currently `laravel`) into `iso/`. To build
another profile, run the same command with a different `--profile`:

```sh
docker compose run --rm spinner "sh aports/scripts/mkimage.sh --tag v3.24 --outdir iso --arch x86_64 \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
  --profile wordpress"
```

The result is `iso/alpine-v3.24-<profile>-x86_64.iso`.

## Smoke test

```sh
tests/smoke-test.sh              # every ISO in iso/
tests/smoke-test.sh lamp node    # only these profiles
```

Boots each ISO headless in QEMU with an empty shared directory and a blank
database disk, then checks that the VM reaches a login prompt, sshd and
node_exporter answer, the stack serves its page with a working database (the
noVNC page and the VNC server for `x11`), and the files created in the shared
directory belong to you. The monitoring profiles get companion VMs on a
monitoring network of the test's own and must monitor them: a `node` VM for
`prometheus` and `zabbix` (scraped, agent available in Zabbix), and a
`prometheus` and a `zabbix` VM for `grafana` (working data sources), so build
those ISOs too. It needs `curl` and takes a few minutes per profile. The exit status is
non-zero if any profile fails, and the work directory (serial log, shared
directory, fetched pages) is kept for inspection.

The test uses host ports 18080–18084 and the multicast group
`230.0.0.1:19080`; set `SMOKE_PORT_BASE` (and `SMOKE_MCAST`) to move them.
`SMOKE_TIMEOUT` (seconds per check, default 300) and `SMOKE_KEEP=yes` (keep
the work directory) are also available. A `laravel` image tested offline
passes with its starter page.

## Lint

```sh
./project.sh lint
```

Runs [ShellCheck](https://www.shellcheck.net) (in the `koalaman/shellcheck`
container) on the project's own scripts, with the settings in `.shellcheckrc`.
CI runs the same command on every push to `main` and every pull request.

## Run

Run the commands from the repository root, since the ISO path is relative.
All examples forward guest ports to `127.0.0.1` on the host only, and SSH to
port 2222. Keep the shared directories **outside** this repository (see
[Clean](#clean)).

- The database disk is optional: if you skip the `qemu-img create` line,
  also drop the matching `-drive` line.
- `-enable-kvm` needs read/write access to `/dev/kvm` (usually membership in
  the `kvm` group). Without it, drop the flag; the VM then runs much slower.
- If the VM window shows `Nothing to boot`, the firmware found nothing
  bootable and fell back to network boot. That usually means the ISO wasn't
  attached as a CD: check that the `-cdrom` path points to the built ISO.

### django

```sh
mkdir -p ~/django-dev
qemu-img create -f qcow2 ~/django-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-django-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:8000,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/django-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/django-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a new project (`django-admin startproject
  mysite`) set up for PostgreSQL. Django 5.2 comes from Alpine, so this works
  offline. Existing files are never touched.
- The project runs with `manage.py runserver` on port 8000 in the guest,
  which reloads by itself when a Python file changes. On every start
  `manage.py migrate` runs and the admin user is created if it's missing:
  log in at `/admin` as `admin` / `admin`.
- With a `requirements.txt`, its packages are installed with pip (needs
  internet) into a virtualenv in the guest that also sees Alpine's Django and
  psycopg. After changing it, run `rc-service django-app restart` in the VM.
- The app gets `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and
  `PGPASSWORD` in its environment; the new project's `settings.py` reads
  them. Database `app`, user `app`, password `app`. The user may create
  databases, so `manage.py test` works.
- App output: `/var/log/django-app.log` in the guest.

### drupal

```sh
mkdir -p ~/drupal-dev
qemu-img create -f qcow2 ~/drupal-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-drupal-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/drupal-dev",mount_tag=drupal,security_model=none,id=drupal \
  -drive file="$HOME/drupal-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets Drupal core and a `settings.php` on first
  boot, and the site is installed (standard profile). Drupal is bundled in
  the image, so the first boot works offline.
- The site is installed already: log in at `/user/login` as `admin` /
  `admin`.
- A directory that already holds a Drupal site is served as it is: the
  tarball layout, or a Composer project (`drupal/recommended-project`)
  served from `web/`. Any other non-empty directory is served unchanged.
- The installer runs again whenever the database is empty, but only if
  `settings.php` is the one the VM wrote (it has a `qemu-recipes: managed`
  line). Without a database disk, that means a fresh site on every boot.
- Errors are shown on the page, CSS/JS aggregation is off, and
  `sites/default` stays writable so you can edit `settings.php` from the
  host. Composer and Drush aren't included.

### grafana

```sh
mkdir -p ~/grafana-dev
qemu-img create -f qcow2 ~/grafana-data.qcow2 2G        # optional: keeps the data
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-grafana-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:3000-:3000,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/grafana-dev",mount_tag=grafana,security_model=none,id=grafana \
  -drive file="$HOME/grafana-data.qcow2",if=virtio,format=qcow2
```

- Every `prometheus` and `zabbix` VM on the monitoring network becomes a data
  source, "Prometheus on <vm>" or "Zabbix on <vm>", within about 10 seconds
  of showing up. A data source stays when its VM goes away, and follows the
  VM when its address changes.
- Log in as `admin` / `admin`. The dashboards "VMs (Prometheus)" and
  "VMs (Zabbix)" (folder qemu-recipes) let you pick the data source.
- JSON files in `dashboards/` of the shared directory appear in the folder
  "Shared" and are re-read every 10 seconds, so you can edit dashboards on
  the host.
- The Zabbix plugin is bundled in the image. Discovered Zabbix VMs are
  queried as `Admin` / `zabbix` (see [Build-time settings](#build-time-settings)).

### joomla

```sh
mkdir -p ~/joomla-dev
qemu-img create -f qcow2 ~/joomla-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-joomla-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/joomla-dev",mount_tag=joomla,security_model=none,id=joomla \
  -drive file="$HOME/joomla-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets Joomla on first boot, and the site is
  installed with Joomla's CLI installer. Joomla is bundled in the image, so
  the first boot works offline. A non-empty directory is served as it is.
- The site is installed already: log in at `/administrator` as `admin` /
  `admin-password` (Joomla requires at least 12 characters).
- Search-engine-friendly URLs with `.htaccess` rewriting are on, and error
  reporting is set to maximum.
- The installer runs again whenever the database is empty and
  `configuration.php` points at the VM's database (`joomla`), keeping your
  `configuration.php`. Without a database disk, that means a fresh site on
  every boot.

### lamp

```sh
mkdir -p ~/lamp-dev
qemu-img create -f qcow2 ~/lamp-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-lamp-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/lamp-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/lamp-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a starter `index.php` (`phpinfo()` and a
  database check). PHP errors are shown on the page.
- Database `app`, user `app`, password `app`:
  `new mysqli('localhost', 'app', 'app', 'app')`.

### laravel

A lighter LAMP-like stack that runs a full Laravel project: lighttpd instead
of Apache, PHP 8.5 through PHP-FPM, MariaDB tuned for low memory, Composer,
the Laravel scheduler and a queue worker. 1 GB of RAM is enough.

```sh
mkdir -p ~/laravel-dev
qemu-img create -f qcow2 ~/laravel-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 1024 -smp 2 -cdrom iso/alpine-v3.24-laravel-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:3307-:3306,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/laravel-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/laravel-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a new Laravel project on first boot
  (`composer create-project`, needs internet; the site is up after about two
  minutes).
  Its `.env` is set up for MariaDB and the migrations have run. Offline, or
  with `LARAVEL_CREATE=no`, it gets a starter `index.php` instead. To create
  the project again, empty the directory and reboot.
- If `public/index.php` exists, `public/` is served (Laravel, Symfony, ...);
  otherwise the directory itself. Requests for anything that isn't a file go
  to `index.php`. After switching between the two layouts, run
  `rc-service lighttpd restart` in the VM.
- `php artisan schedule:run` runs every minute from cron, and
  `php artisan queue:listen` runs as a service; both pick up code changes
  without a restart. Queue output: `/var/log/laravel-queue.log`.
- Database `app`, user `app`, password `app`. In the VM, Laravel connects
  through the socket (`DB_SOCKET=/run/mysqld/mysqld.sock`). From the host,
  connect a database client to `127.0.0.1:3307`.
- Run `composer` and `php artisan` inside the VM (over SSH or the console):
  PHP and its extensions there match what the site runs on.
- Node.js isn't included. Build front-end assets on the host
  (`npm run build`), or run `npm run dev` on the host: Vite writes
  `public/hot` into the shared directory and the browser loads assets from
  the host's dev server.

### node

```sh
mkdir -p ~/node-dev
qemu-img create -f qcow2 ~/node-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-node-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:3000,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/node-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/node-db.qcow2",if=virtio,format=qcow2
```

- The app listens on port 3000 in the guest.
- An empty shared directory gets a starter `package.json` and `server.js`.
  The `postgres` client is bundled, so it works offline.
- The VM runs `npm start` (or `server.js` / `index.js`) and restarts the app
  within a few seconds of a change to a source file (`.js`, `.mjs`, `.cjs`,
  `.ts`, `.mts`, `.cts`, `.jsx`, `.tsx`, `.json`) or `.env*`. Files the app
  writes itself (logs, uploads, SQLite databases) don't trigger a restart.
  `node_modules` and `.git` are ignored. Change the list with `WATCH_EXT` in
  `/etc/conf.d/node` in the VM.
- `npm install` runs automatically when `node_modules` is missing or older
  than `package.json` (needs internet). Install packages with native code
  inside the VM: the guest is musl based, so modules built on a glibc host
  won't load.
- The app gets `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
  `PGPASSWORD`, `PORT` and `NODE_ENV` in its environment. Database `app`,
  user `app`, password `app`.
- App output: `/var/log/node-app.log` in the guest.

### prometheus

```sh
mkdir -p ~/prometheus-dev
qemu-img create -f qcow2 ~/prometheus-data.qcow2 4G     # optional: keeps the data
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-prometheus-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:3000-:3000,hostfwd=tcp:127.0.0.1:9090-:9090,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/prometheus-dev",mount_tag=prometheus,security_model=none,id=prometheus \
  -drive file="$HOME/prometheus-data.qcow2",if=virtio,format=qcow2
```

- Every VM on the monitoring network is scraped (its node_exporter) as job
  `node`, labelled `instance` (the VM's name) and `profile`, within about
  10 seconds of showing up. The prometheus VM itself is in there too.
- Grafana (`admin` / `admin`) has Prometheus as its default data source and
  the dashboard "VMs (Prometheus)": CPU, memory, load, root filesystem and
  network per VM.
- The shared directory holds `rules/*.yml` (alerting and recording rules,
  starting with an example `VMDown` alert), `scrape/*.yml` (more scrape
  configs, for your own exporters) and `dashboards/*.json` (Grafana, folder
  "Shared"). Prometheus is reloaded within about 10 seconds of a change.
- Samples are kept for 15 days (`PROMETHEUS_RETENTION`).

### wordpress

```sh
mkdir -p ~/wordpress-dev
qemu-img create -f qcow2 ~/wordpress-db.qcow2 4G        # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-wordpress-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/wordpress-dev",mount_tag=wordpress,security_model=none,id=wordpress \
  -drive file="$HOME/wordpress-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets WordPress core and `wp-config.php` on first
  boot; existing files are never overwritten. WordPress is bundled in the
  image, so the first boot works offline.
- The site is installed already: log in at `/wp-admin` as `admin` / `admin`.
- The site URL follows the host and port you open it with.
- `WP_DEBUG` is on, with errors logged to `wp-content/debug.log`.

### x11

```sh
mkdir -p ~/x11-home
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-v3.24-x11-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:5900-:5900,hostfwd=tcp:127.0.0.1:6080-:6080,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/x11-home",mount_tag=home,security_model=none,id=home
```

- Connect with any VNC viewer on `localhost:5900`, or with just a browser
  through noVNC on port 6080 (URL in the table above).
- The X server is TigerVNC's `Xvnc`: no graphics card is needed, the desktop
  follows the viewer's window size and the clipboard is shared.
- The shared directory is the home of user `alpine`. If `~/.xsession` exists
  and is executable it runs instead of plain openbox; log out of openbox to
  restart the session with your changes.
- `doas` gives root without a password.
- There is no sound over VNC, and OpenGL runs on the CPU (llvmpipe).

### zabbix

```sh
mkdir -p ~/zabbix-dev
qemu-img create -f qcow2 ~/zabbix-data.qcow2 8G         # optional: keeps the data
qemu-system-x86_64 -enable-kvm -m 3072 -smp 2 -cdrom iso/alpine-v3.24-zabbix-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:3000-:3000,hostfwd=tcp:127.0.0.1:2222-:22 \
  -nic socket,model=virtio-net-pci,mcast=230.0.0.1:1234,localaddr=127.0.0.1 \
  -virtfs local,path="$HOME/zabbix-dev",mount_tag=zabbix,security_model=none,id=zabbix \
  -drive file="$HOME/zabbix-data.qcow2",if=virtio,format=qcow2
```

- Zabbix 7.4 (server and frontend, on PostgreSQL 18). Log in as `Admin` /
  `zabbix`. On first boot the database is created, which takes about a
  minute.
- Every VM on the monitoring network becomes a host within about 30 seconds
  of showing up: group "qemu-recipes VMs", template "Linux by Zabbix agent"
  (checked through the VM's zabbix_agent2), tag `profile`. When a VM comes
  back with another address, its host is updated. The zabbix VM itself is
  the host "Zabbix server".
- Grafana (`admin` / `admin`) has the Zabbix plugin, Zabbix as its default
  data source and the dashboard "VMs (Zabbix)". JSON files in `dashboards/`
  of the shared directory appear in the folder "Shared".
- 3 GB of RAM: Zabbix, PostgreSQL, PHP and Grafana all run from RAM.

## Monitoring network

Every VM can join a virtual LAN that all VMs on this host share: the
`-nic socket,...,mcast=230.0.0.1:1234,localaddr=127.0.0.1` line in the
examples above. It needs no root and stays on the host (loopback). Without
that line a VM works as before, it just can't be monitored by the others.

- In the guest that second NIC is `eth1`. It gets a random MAC (QEMU gives
  every VM the same default one) and an IPv4 link-local address
  (169.254.x.x), so no DHCP server is needed.
- Every VM announces itself there over mDNS (avahi) as a
  `_qemu-recipes._tcp` service, with its profile and the ports of its
  agents. Two VMs with the same name get unique ones (`node`, `node-2`).
- Every VM runs node_exporter (port 9100) for Prometheus and zabbix_agent2
  (port 10050, passive checks from the monitoring network) for Zabbix.
- The `prometheus`, `zabbix` and `grafana` VMs browse these announcements
  and set themselves up: start them in any order, and start or stop other
  VMs whenever you like.
- `qemu-recipes-peers` in a monitoring VM lists what it sees.
- To use a real LAN instead, bridge the second NIC to it (for example with
  `-nic bridge,br=br0,model=virtio-net-pci`): VMs on other hosts then show up
  too. Link-local addresses and mDNS don't cross routers.
- Use another group or port (`mcast=230.0.0.1:1235`) for a separate set of
  VMs.

## How sharing and persistence work

- **Permissions.** The service in the VM (Apache, PHP-FPM, the Node app,
  Django's runserver, the X session) runs with the uid/gid that owns the shared directory on the host,
  so files created on either side stay editable on both. This relies on
  `security_model=none` in `-virtfs`.
- **Without `-virtfs`** the shared directory lives in the VM's RAM instead.
- **Database disk.** On first boot the first blank virtio disk is formatted
  (ext4, labelled `djangodb`, `drupaldb`, `grafanadb`, `joomladb`, `lampdb`,
  `laraveldb`, `nodedb`, `promdb`, `wpdb` or `zabbixdb`) and used for the
  database (for the monitoring profiles: the collected data and Grafana)
  from then on. Without it the database lives in RAM. Either way, anything
  kept in RAM is lost on poweroff.
- **SSH.** Put your public key into `~/.ssh/authorized_keys` of the x11 shared
  home to log in with `ssh -p 2222 alpine@localhost`. The other profiles have
  no password or key for root, so use the QEMU console there.

## Build-time settings

Pass these as environment variables to the build container with `-e`,
placed before the service name:

```sh
docker compose run --rm -e LARAVEL_CREATE=no -e DB_PASSWORD=secret spinner \
  "sh aports/scripts/mkimage.sh --tag v3.24 --outdir iso --arch x86_64 \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
  --profile laravel"
```

They end up in `/etc/conf.d/<profile>` in the guest.

| Profile     | Variable              | Default                  |
|-------------|-----------------------|--------------------------|
| `django`    | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
|             | `APP_PORT`            | `8000`                   |
|             | `DJANGO_PROJECT`      | `mysite`                 |
|             | `DJANGO_ADMIN_USER`   | `admin` (empty: none)    |
|             | `DJANGO_ADMIN_PASSWORD` | `admin`                |
|             | `DJANGO_ADMIN_EMAIL`  | `admin@example.com`      |
| `drupal`    | `DRUPAL_SITE_NAME`    | `Drupal Dev`             |
|             | `DRUPAL_ADMIN_USER`   | `admin`                  |
|             | `DRUPAL_ADMIN_PASSWORD` | `admin`                |
|             | `DRUPAL_ADMIN_EMAIL`  | `admin@example.com`      |
|             | `DRUPAL_PROFILE`      | `standard`               |
|             | `DRUPAL_VERSION`      | `latest`                 |
|             | `DRUPAL_TARBALL`      | (download)               |
| `grafana`   | `GRAFANA_ADMIN_USER`  | `admin`                  |
|             | `GRAFANA_ADMIN_PASSWORD` | `admin`               |
|             | `ZABBIX_USER`, `ZABBIX_PASSWORD` | `Admin`, `zabbix` (for discovered Zabbix VMs) |
|             | `GRAFANA_ZABBIX_PLUGIN_VERSION` | `latest`       |
| `joomla`    | `JOOMLA_SITE_NAME`    | `Joomla Dev`             |
|             | `JOOMLA_ADMIN_USER`   | `admin`                  |
|             | `JOOMLA_ADMIN_PASSWORD` | `admin-password` (12+ characters) |
|             | `JOOMLA_ADMIN_EMAIL`  | `admin@example.com`      |
|             | `JOOMLA_VERSION`      | `latest`                 |
|             | `JOOMLA_TARBALL`      | (download)               |
| `lamp`      | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
| `laravel`   | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
|             | `APP_URL`             | `http://localhost:8080`  |
|             | `LARAVEL_CREATE`      | `yes`                    |
|             | `LARAVEL_VERSION`     | (latest)                 |
| `node`      | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
|             | `APP_PORT`            | `3000`                   |
|             | `POSTGRES_JS_VERSION` | `latest`                 |
| `prometheus` | `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | `admin` |
|             | `PROMETHEUS_RETENTION` | `15d`                   |
|             | `SCRAPE_INTERVAL`     | `15s`                    |
| `wordpress` | `WP_URL`              | `http://localhost:8080`  |
|             | `WP_TITLE`            | `WordPress Dev`          |
|             | `WP_ADMIN_USER`       | `admin`                  |
|             | `WP_ADMIN_PASSWORD`   | `admin`                  |
|             | `WP_ADMIN_EMAIL`      | `admin@example.com`      |
|             | `WP_VERSION`          | `latest`                 |
|             | `WP_TARBALL`          | (download)               |
| `x11`       | `X11_USER`            | `alpine`                 |
|             | `VNC_GEOMETRY`        | `1920x1080`              |
|             | `VNC_PASSWORD`        | (none)                   |
| `zabbix`    | `ZABBIX_ADMIN_PASSWORD` | `zabbix`               |
|             | `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | `admin` |
|             | `GRAFANA_ZABBIX_PLUGIN_VERSION` | `latest`       |

The defaults are weak development credentials. Don't expose these VMs beyond
your own machine.

## Clean

```sh
./project.sh clean
```

Removes the cloned `aports` tree (keeping the profile scripts), `iso/` and
build leftovers. It deletes the contents of every top-level directory of this
repository except `tests/`, so don't keep a shared directory inside it.

## License

The recipes are licensed under the [MIT License](LICENSE). The ISOs are built
from Alpine Linux packages and Alpine's `aports` scripts, which keep their own
licenses.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## QEMU recipes for custom Alpine Linux images

Ready-to-boot Alpine Linux (3.24 stable, x86_64) ISO images for QEMU development VMs.
Each image starts its stack on boot with no installation or configuration
inside the guest, and shares a host directory with the VM over virtio-9p, so
you can edit files on the host and see the result in the VM right away.

| Profile     | What boots                                    | Shared host dir is | Open on the host                          |
|-------------|-----------------------------------------------|--------------------|-------------------------------------------|
| `django`    | Django 5.2 (runserver), PostgreSQL 18         | `/var/www/html`    | <http://localhost:8080>                   |
| `drupal`    | Apache, PHP 8.4, MariaDB, installed Drupal    | `/var/www/html`    | <http://localhost:8080>                   |
| `joomla`    | Apache, PHP 8.4, MariaDB, installed Joomla    | `/var/www/html`    | <http://localhost:8080>                   |
| `lamp`      | Apache, PHP 8.4, MariaDB                      | `/var/www/html`    | <http://localhost:8080>                   |
| `laravel`   | lighttpd, PHP 8.5 (FPM), MariaDB, Composer    | `/var/www/html`    | <http://localhost:8080>                   |
| `node`      | Node.js 24, PostgreSQL 18                     | `/var/www/html`    | <http://localhost:8080>                   |
| `wordpress` | Apache, PHP 8.4, MariaDB, installed WordPress | `/var/www/html`    | <http://localhost:8080>                   |
| `x11`       | X11 desktop (openbox) over VNC / noVNC        | `/home/alpine`     | <http://localhost:6080/vnc.html?autoconnect=1&resize=remote> or `vncviewer localhost:5900` |

Each profile is a pair of scripts in `aports/scripts/`: `mkimg.<profile>.sh`
lists the packages put on the ISO, and `genapkovl-<profile>.sh` generates the
boot overlay (config, services) that sets everything up.

### Requirements

- Docker with the compose plugin (the image is built in the
  [`aljazmc/image-spinner`](https://hub.docker.com/r/aljazmc/image-spinner) container)
- QEMU (`qemu-system-x86_64`, `qemu-img`); KVM is recommended
- Internet access while building

### Build

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

The result is `iso/alpine-<profile>-v3.24-x86_64.iso`.

### Smoke test

```sh
tests/smoke-test.sh              # every ISO in iso/
tests/smoke-test.sh lamp node    # only these profiles
```

Boots each ISO headless in QEMU with an empty shared directory and a blank
database disk, then checks that the VM reaches a login prompt, sshd answers,
the stack serves its page with a working database (the noVNC page and the VNC
server for `x11`), and the files created in the shared directory belong to
you. It needs `curl` and takes a few minutes per profile. The exit status is
non-zero if any profile fails, and the work directory (serial log, shared
directory, fetched pages) is kept for inspection.

The test uses host ports 18080–18082; set `SMOKE_PORT_BASE` to move them.
`SMOKE_TIMEOUT` (seconds per check, default 300) and `SMOKE_KEEP=yes` (keep
the work directory) are also available. A `laravel` image tested offline
passes with its starter page.

### Run

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

#### django

```sh
mkdir -p ~/django-dev
qemu-img create -f qcow2 ~/django-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-django-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:8000,hostfwd=tcp:127.0.0.1:2222-:22 \
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

#### drupal

```sh
mkdir -p ~/drupal-dev
qemu-img create -f qcow2 ~/drupal-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-drupal-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
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

#### joomla

```sh
mkdir -p ~/joomla-dev
qemu-img create -f qcow2 ~/joomla-db.qcow2 4G           # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-joomla-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
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

#### lamp

```sh
mkdir -p ~/lamp-dev
qemu-img create -f qcow2 ~/lamp-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-lamp-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -virtfs local,path="$HOME/lamp-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/lamp-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a starter `index.php` (`phpinfo()` and a
  database check). PHP errors are shown on the page.
- Database `app`, user `app`, password `app`:
  `new mysqli('localhost', 'app', 'app', 'app')`.

#### laravel

A lighter LAMP-like stack that runs a full Laravel project: lighttpd instead
of Apache, PHP 8.5 through PHP-FPM, MariaDB tuned for low memory, Composer,
the Laravel scheduler and a queue worker. 1 GB of RAM is enough.

```sh
mkdir -p ~/laravel-dev
qemu-img create -f qcow2 ~/laravel-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 1024 -smp 2 -cdrom iso/alpine-laravel-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:3307-:3306,hostfwd=tcp:127.0.0.1:2222-:22 \
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

#### node

```sh
mkdir -p ~/node-dev
qemu-img create -f qcow2 ~/node-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-node-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:3000,hostfwd=tcp:127.0.0.1:2222-:22 \
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

#### wordpress

```sh
mkdir -p ~/wordpress-dev
qemu-img create -f qcow2 ~/wordpress-db.qcow2 4G        # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-wordpress-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -virtfs local,path="$HOME/wordpress-dev",mount_tag=wordpress,security_model=none,id=wordpress \
  -drive file="$HOME/wordpress-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets WordPress core and `wp-config.php` on first
  boot; existing files are never overwritten. WordPress is bundled in the
  image, so the first boot works offline.
- The site is installed already: log in at `/wp-admin` as `admin` / `admin`.
- The site URL follows the host and port you open it with.
- `WP_DEBUG` is on, with errors logged to `wp-content/debug.log`.

#### x11

```sh
mkdir -p ~/x11-home
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-x11-v3.24-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:5900-:5900,hostfwd=tcp:127.0.0.1:6080-:6080,hostfwd=tcp:127.0.0.1:2222-:22 \
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

### How sharing and persistence work

- **Permissions.** The service in the VM (Apache, PHP-FPM, the Node app,
  Django's runserver, the X session) runs with the uid/gid that owns the shared directory on the host,
  so files created on either side stay editable on both. This relies on
  `security_model=none` in `-virtfs`.
- **Without `-virtfs`** the shared directory lives in the VM's RAM instead.
- **Database disk.** On first boot the first blank virtio disk is formatted
  (ext4, labelled `djangodb`, `drupaldb`, `joomladb`, `lampdb`, `laraveldb`,
  `nodedb` or `wpdb`) and used for the database
  from then on. Without it the database lives in RAM. Either way, anything
  kept in RAM is lost on poweroff.
- **SSH.** Put your public key into `~/.ssh/authorized_keys` of the x11 shared
  home to log in with `ssh -p 2222 alpine@localhost`. The other profiles have
  no password or key for root, so use the QEMU console there.

### Build-time settings

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

The defaults are weak development credentials. Don't expose these VMs beyond
your own machine.

### Clean

```sh
./project.sh clean
```

Removes the cloned `aports` tree (keeping the profile scripts), `iso/` and
build leftovers. It deletes the contents of every top-level directory of this
repository except `tests/`, so don't keep a shared directory inside it.

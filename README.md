[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## QEMU recipes for custom Alpine Linux images

Ready-to-boot Alpine Linux (edge, x86_64) ISO images for QEMU development VMs.
Each image starts its stack on boot with no installation or configuration
inside the guest, and shares a host directory with the VM over virtio-9p, so
you can edit files on the host and see the result in the VM right away.

| Profile     | What boots                                    | Shared host dir is | Open on the host                          |
|-------------|-----------------------------------------------|--------------------|-------------------------------------------|
| `wordpress` | Apache, PHP 8.4, MariaDB, installed WordPress | `/var/www/html`    | <http://localhost:8080>                   |
| `lamp`      | Apache, PHP 8.4, MariaDB                      | `/var/www/html`    | <http://localhost:8080>                   |
| `test`      | lighttpd, PHP 8.5 (FPM), MariaDB, Composer    | `/var/www/html`    | <http://localhost:8080>                   |
| `node`      | Node.js 24, PostgreSQL 18                     | `/var/www/html`    | <http://localhost:8080>                   |
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

This clones `aports` on first run and builds the `x11` profile into `iso/`.
To build another profile, run the same command with a different `--profile`:

```sh
docker compose run --rm spinner "sh aports/scripts/mkimage.sh --tag edge --outdir iso --arch x86_64 \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/edge/community \
  --profile wordpress"
```

The result is `iso/alpine-<profile>-edge-x86_64.iso`.

### Run

All examples forward guest ports to `127.0.0.1` on the host only, and SSH to
port 2222. Keep the shared directories **outside** this repository (see
[Clean](#clean)).

#### wordpress

```sh
mkdir -p ~/wordpress-dev
qemu-img create -f qcow2 ~/wordpress-db.qcow2 4G        # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-wordpress-edge-x86_64.iso \
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

#### lamp

```sh
mkdir -p ~/lamp-dev
qemu-img create -f qcow2 ~/lamp-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-lamp-edge-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:2222-:22 \
  -virtfs local,path="$HOME/lamp-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/lamp-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a starter `index.php` (`phpinfo()` and a
  database check). PHP errors are shown on the page.
- Database `app`, user `app`, password `app`:
  `new mysqli('localhost', 'app', 'app', 'app')`.

#### test

A lighter LAMP-like stack that runs a full Laravel project: lighttpd instead
of Apache, PHP 8.5 through PHP-FPM, MariaDB tuned for low memory, Composer,
the Laravel scheduler and a queue worker. 1 GB of RAM is enough.

```sh
mkdir -p ~/test-dev
qemu-img create -f qcow2 ~/test-db.qcow2 4G             # optional: keeps the database
qemu-system-x86_64 -enable-kvm -m 1024 -smp 2 -cdrom iso/alpine-test-edge-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:3307-:3306,hostfwd=tcp:127.0.0.1:2222-:22 \
  -virtfs local,path="$HOME/test-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/test-db.qcow2",if=virtio,format=qcow2
```

- An empty shared directory gets a new Laravel project on first boot
  (`composer create-project`, needs internet; about 15 seconds plus copying).
  Its `.env` is set up for MariaDB and the migrations have run. Offline, or
  with `LARAVEL_CREATE=no`, it gets a starter `index.php` instead. To create
  the project again, empty the directory and reboot.
- If `public/index.php` exists, `public/` is served (Laravel, Symfony, ...);
  otherwise the directory itself. Requests for anything that isn't a file go
  to `index.php`. After switching between the two layouts, run
  `rc-service lighttpd restart` in the VM.
- `php artisan schedule:run` runs every minute from cron, and
  `php artisan queue:listen` runs as a service; both pick up code changes
  without a restart. Queue output: `/var/log/test-queue.log`.
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
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-node-edge-x86_64.iso \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:3000,hostfwd=tcp:127.0.0.1:2222-:22 \
  -virtfs local,path="$HOME/node-dev",mount_tag=www,security_model=none,id=www \
  -drive file="$HOME/node-db.qcow2",if=virtio,format=qcow2
```

- The app listens on port 3000 in the guest.
- An empty shared directory gets a starter `package.json` and `server.js`.
  The `postgres` client is bundled, so it works offline.
- The VM runs `npm start` (or `server.js` / `index.js`) and restarts the app
  within about a second of any file change. `node_modules` and `.git` are
  ignored.
- `npm install` runs automatically when `node_modules` is missing or older
  than `package.json` (needs internet). Install packages with native code
  inside the VM: the guest is musl based, so modules built on a glibc host
  won't load.
- The app gets `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
  `PGPASSWORD`, `PORT` and `NODE_ENV` in its environment. Database `app`,
  user `app`, password `app`.
- App output: `/var/log/node-app.log` in the guest.

#### x11

```sh
mkdir -p ~/x11-home
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -cdrom iso/alpine-x11-edge-x86_64.iso \
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
  the X session) runs with the uid/gid that owns the shared directory on the host,
  so files created on either side stay editable on both. This relies on
  `security_model=none` in `-virtfs`.
- **Without `-virtfs`** the shared directory lives in the VM's RAM instead.
- **Database disk.** On first boot the first blank virtio disk is formatted
  (ext4, labelled `wpdb`, `lampdb`, `testdb` or `nodedb`) and used for the database
  from then on. Without it the database lives in RAM. Either way, anything
  kept in RAM is lost on poweroff.
- **SSH.** Put your public key into `~/.ssh/authorized_keys` of the x11 shared
  home to log in with `ssh -p 2222 alpine@localhost`. The other profiles have
  no password or key for root, so use the QEMU console there.

### Build-time settings

Set these as environment variables for the build (for example, add
`-e VNC_PASSWORD=secret` to `docker compose run`). They end up in
`/etc/conf.d/<profile>` in the guest.

| Profile     | Variable              | Default                  |
|-------------|-----------------------|--------------------------|
| `wordpress` | `WP_URL`              | `http://localhost:8080`  |
|             | `WP_TITLE`            | `WordPress Dev`          |
|             | `WP_ADMIN_USER`       | `admin`                  |
|             | `WP_ADMIN_PASSWORD`   | `admin`                  |
|             | `WP_ADMIN_EMAIL`      | `admin@example.com`      |
|             | `WP_VERSION`          | `latest`                 |
|             | `WP_TARBALL`          | (download)               |
| `lamp`      | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
| `test`      | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
|             | `APP_URL`             | `http://localhost:8080`  |
|             | `LARAVEL_CREATE`      | `yes`                    |
|             | `LARAVEL_VERSION`     | (latest)                 |
| `node`      | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `app`      |
|             | `APP_PORT`            | `3000`                   |
|             | `POSTGRES_JS_VERSION` | `latest`                 |
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
repository, so don't keep a shared directory inside it.

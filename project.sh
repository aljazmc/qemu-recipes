#!/bin/sh

ALPINE_VERSION=3.24
SHELLCHECK_VERSION=v0.11.0

clean() {

find . -mindepth 2 -maxdepth 2 \
    | sed "
        /aports\/scripts/d;
        /\.\/\.git/d;
        /\.\/\.github/d;
        /\.\/tests/d;
    " \
    | xargs -I {} rm -rf {}

find aports/scripts -mindepth 1 -maxdepth 1 \
    | sed "
        /aports\/scripts\/genapkovl-django.sh/d;
        /aports\/scripts\/genapkovl-drupal.sh/d;
        /aports\/scripts\/genapkovl-grafana.sh/d;
        /aports\/scripts\/genapkovl-joomla.sh/d;
        /aports\/scripts\/genapkovl-lamp.sh/d;
        /aports\/scripts\/genapkovl-laravel.sh/d;
        /aports\/scripts\/genapkovl-node.sh/d;
        /aports\/scripts\/genapkovl-prometheus.sh/d;
        /aports\/scripts\/genapkovl-wordpress.sh/d;
        /aports\/scripts\/genapkovl-x11.sh/d;
        /aports\/scripts\/genapkovl-zabbix.sh/d;
        /aports\/scripts\/mkimg.django.sh/d;
        /aports\/scripts\/mkimg.drupal.sh/d;
        /aports\/scripts\/mkimg.grafana.sh/d;
        /aports\/scripts\/mkimg.joomla.sh/d;
        /aports\/scripts\/mkimg.lamp.sh/d;
        /aports\/scripts\/mkimg.laravel.sh/d;
        /aports\/scripts\/mkimg.node.sh/d;
        /aports\/scripts\/mkimg.prometheus.sh/d;
        /aports\/scripts\/mkimg.wordpress.sh/d;
        /aports\/scripts\/mkimg.x11.sh/d;
        /aports\/scripts\/mkimg.zabbix.sh/d;
        /aports\/scripts\/monitoring-agent.sh/d;
        /aports\/scripts\/monitoring-grafana.sh/d;
    " \
    | xargs -I {} rm -rf {}

rm -rf .abuild alpine.qcow2 .ash_history iso

}

lint() {

## shellcheck the project's own scripts (not the rest of aports)

git ls-files -z project.sh '*.sh' \
    | xargs -0 docker run --rm -v "$PWD:/mnt" -w /mnt "koalaman/shellcheck:${SHELLCHECK_VERSION}"

}

start() {

## clone aports if it doesn't already exist

if [ ! -d aports/main ]; then

    docker compose run --rm spinner "git clone --depth=1 --branch ${ALPINE_VERSION}-stable https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports && rsync -auq /tmp/aports/ aports/ && docker-entrypoint.sh"

fi

docker compose run --rm spinner "sh aports/scripts/mkimage.sh --tag v${ALPINE_VERSION} --outdir iso --arch x86_64 --repository https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main --repository https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community --profile laravel"

}

$1

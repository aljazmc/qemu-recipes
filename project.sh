#!/bin/sh

clean() {

find . -mindepth 2 -maxdepth 2 \
    | sed "
        /aports\/scripts/d;
        /\.\/\.git/d;
    " \
    | xargs -I {} rm -rf {}

find aports/scripts -mindepth 1 -maxdepth 1 \
    | sed "
        /aports\/scripts\/genapkovl-test.sh/d;
        /aports\/scripts\/genapkovl-x11.sh/d;
        /aports\/scripts\/mkimg.test.sh/d;
        /aports\/scripts\/mkimg.x11.sh/d;
    " \
    | xargs -I {} rm -rf {}

rm -rf .abuild alpine.qcow2 .ash_history iso

}

start() {

## clone aports if it doesn't already exist

if [ ! -d aports/main ]; then

    docker compose run --rm spinner

fi

docker compose run --rm spinner "sh aports/scripts/mkimage.sh --tag edge --outdir iso --arch x86_64 --repository https://dl-cdn.alpinelinux.org/alpine/edge/main --repository https://dl-cdn.alpinelinux.org/alpine/edge/community --profile x11"

}

$1

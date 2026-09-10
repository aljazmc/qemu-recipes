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
        /aports\/scripts\/mkimg.test.sh/d;
    " \
    | xargs -I {} rm -rf {}

rm -rf .abuild alpine.qcow2 iso

}

$1

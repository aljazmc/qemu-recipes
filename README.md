[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## QEMU recipes for creating custom Alpine Linux images

Depends on [Image Spinner](https://github.com/aljazmc/dockerfiles/tree/main/image-spinner) Docker image.

## Workflow example:
1. clone the repository with `git clone https://github.com/aljazmc/qemu-recipes`.
2. cd `qemu-recipes`.
3. use `docker compose run --rm spinner` to clone aports to non-empty directory
4. prepare/choose recipe in `aports/scripts` directory.
5. generate custom ISO with `docker compose run --rm spinner sh -c "sh aports/scripts/mkimage.sh --tag edge --outdir iso --arch x86_64 --repository https://dl-cdn.alpinelinux.org/alpine/edge/main --repository https://dl-cdn.alpinelinux.org/alpine/edge/community --profile test"`
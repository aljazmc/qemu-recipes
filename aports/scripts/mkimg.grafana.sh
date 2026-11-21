# shellcheck shell=sh disable=SC2034,SC2154
# Sourced by aports' mkimage.sh, which sets image_ext etc. and reads the
# variables set here (title, apks, apkovl, output_filename, ...)

profile_grafana() {
    profile_virt
    kernel_flavors="virt"
    # root tmpfs (diskless): up to 75% of RAM instead of 50%, the packages live there
    kernel_cmdline="$kernel_cmdline rootflags=size=75%"
    title="Grafana"
    desc="Grafana with the prometheus and zabbix VMs on the monitoring network as data sources"
    profile_abbrev="grafana"
    hostname="grafana"
    apks="$apks
        blkid
        e2fsprogs
        grafana
        grafana-openrc
        openssh
        openssh-server-common-openrc
        avahi
        avahi-openrc
        avahi-tools
        dbus
        dbus-openrc
        prometheus-node-exporter
        prometheus-node-exporter-openrc
        zabbix-agent2
        zabbix-agent2-openrc
    "
    apkovl="aports/scripts/genapkovl-grafana.sh"
    # alpine-<release>-<profile>-<arch>.iso, e.g. alpine-v3.24-grafana-x86_64.iso
    output_filename="alpine-${RELEASE}-${PROFILE}-${ARCH}.${image_ext}"
}

profile_prometheus() {
    profile_virt
    kernel_flavors="virt"
    # root tmpfs (diskless): up to 75% of RAM instead of 50%, the packages live there
    kernel_cmdline="$kernel_cmdline rootflags=size=75%"
    title="Prometheus"
    desc="Prometheus and Grafana monitoring the qemu-recipes VMs on the monitoring network"
    profile_abbrev="prometheus"
    hostname="prometheus"
    apks="$apks
        blkid
        e2fsprogs
        grafana
        grafana-openrc
        openssh
        openssh-server-common-openrc
        prometheus
        prometheus-openrc
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
    apkovl="aports/scripts/genapkovl-prometheus.sh"
}

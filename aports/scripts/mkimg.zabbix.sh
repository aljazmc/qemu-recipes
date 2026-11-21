profile_zabbix() {
    profile_virt
    kernel_flavors="virt"
    # root tmpfs (diskless): up to 75% of RAM instead of 50%, the packages live there
    kernel_cmdline="$kernel_cmdline rootflags=size=75%"
    title="Zabbix"
    desc="Zabbix and Grafana monitoring the qemu-recipes VMs on the monitoring network"
    profile_abbrev="zabbix"
    hostname="zabbix"
    apks="$apks
        blkid
        e2fsprogs
        grafana
        grafana-openrc
        nginx
        nginx-openrc
        openssh
        openssh-server-common-openrc
        php83
        php83-fpm
        php83-pgsql
        postgresql18
        postgresql18-client
        postgresql18-openrc
        postgresql-common
        postgresql-common-openrc
        zabbix-openrc
        zabbix-pgsql
        zabbix-setup
        zabbix-webif
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
    apkovl="aports/scripts/genapkovl-zabbix.sh"
}

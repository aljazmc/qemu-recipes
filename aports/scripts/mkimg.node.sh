profile_node() {
    profile_virt
    kernel_flavors="virt"
    # root tmpfs (diskless): up to 75% of RAM instead of 50%, the packages live there
    kernel_cmdline="$kernel_cmdline rootflags=size=75%"
    title="Node"
    desc="Self-hosted Node.js development server (Node.js, PostgreSQL 18)"
    profile_abbrev="node"
    hostname="node"
    apks="$apks
        blkid
        e2fsprogs
        nodejs
        npm
        openssh
        openssh-server-common-openrc
        postgresql18
        postgresql18-client
        postgresql18-openrc
        postgresql-common
        postgresql-common-openrc
        avahi
        avahi-openrc
        dbus
        dbus-openrc
        prometheus-node-exporter
        prometheus-node-exporter-openrc
        zabbix-agent2
        zabbix-agent2-openrc
    "
    apkovl="aports/scripts/genapkovl-node.sh"
}

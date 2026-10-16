profile_node() {
    profile_virt
    kernel_flavors="virt"
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
    "
    apkovl="aports/scripts/genapkovl-node.sh"
}

profile_django() {
    profile_virt
    kernel_flavors="virt"
    # root tmpfs (diskless): up to 75% of RAM instead of 50%, the packages live there
    kernel_cmdline="$kernel_cmdline rootflags=size=75%"
    title="Django"
    desc="Self-hosted Django development server (Django 5.2, PostgreSQL 18)"
    profile_abbrev="django"
    hostname="django"
    apks="$apks
        blkid
        e2fsprogs
        openssh
        openssh-server-common-openrc
        postgresql18
        postgresql18-client
        postgresql18-openrc
        postgresql-common
        postgresql-common-openrc
        py3-django
        py3-pip
        py3-psycopg
        python3
        tzdata
        avahi
        avahi-openrc
        dbus
        dbus-openrc
        prometheus-node-exporter
        prometheus-node-exporter-openrc
        zabbix-agent2
        zabbix-agent2-openrc
    "
    apkovl="aports/scripts/genapkovl-django.sh"
    # alpine-<release>-<profile>-<arch>.iso, e.g. alpine-v3.24-django-x86_64.iso
    output_filename="alpine-${RELEASE}-${PROFILE}-${ARCH}.${image_ext}"
}

profile_django() {
    profile_virt
    kernel_flavors="virt"
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
    "
    apkovl="aports/scripts/genapkovl-django.sh"
}

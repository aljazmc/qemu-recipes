profile_test() {
    profile_virt
    kernel_flavors="virt"
    title="LAMP WordPress Server"
    desc="LAMP WordPress Server"
    profile_abbrev="test"
    apks="$apks
        apache2
        php83 php83-apache2 php83-mysqli php83-session php83-gd
        php83-curl php83-mbstring php83-xml php83-zip php83-opcache
        php83-json php83-openssl php83-phar php83-iconv php83-dom
        php83-simplexml php83-fileinfo
        mariadb mariadb-client
        openssh wget unzip
    "
    apkovl="aports/scripts/genapkovl-test.sh"
}

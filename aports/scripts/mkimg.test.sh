profile_test() {
	profile_standard
	profile_realname="LAMP WordPress Server"
	profile_abbrev="test"
	profile_packages="$profile_packages \
		apache2 \
		php83 php83-apache2 php83-mysqli php83-session php83-gd \
		php83-curl php83-mbstring php83-xml php83-zip php83-opcache \
		php83-json php83-openssl php83-phar php83-iconv php83-dom \
		php83-simplexml php83-fileinfo \
		mariadb mariadb-client \
		openssh wget unzip"
	profile_apkovl="genapkovl-test.sh"
}

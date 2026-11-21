# monitoring-grafana.sh - sourced by genapkovl-{grafana,prometheus,zabbix}.sh
#
# Grafana as set up by the monitoring profiles:
# - listens on :3000, admin user from GRAFANA_ADMIN_USER/_PASSWORD,
#   no phoning home (update checks, news, usage reports)
# - data in /var/lib/grafana (the profile's prep service puts it on the
#   persistent disk when there is one)
# - provisioned from /etc/grafana/provisioning; dashboards from
#   /usr/share/qemu-recipes/dashboards (bundled, folder "qemu-recipes") and
#   from <share>/dashboards (folder "Shared", re-read every 10s, so JSON
#   files edited on the host show up right away)
# - optionally with the Zabbix plugin (alexanderzobnin-zabbix-app), bundled
#   at build time
#
# Needs $tmp and makefile from the calling script.

: "${GRAFANA_ADMIN_USER:=admin}"
: "${GRAFANA_ADMIN_PASSWORD:=admin}"
: "${GRAFANA_ZABBIX_PLUGIN_VERSION:=latest}"

GRAFANA_PLUGINS_DIR=/usr/share/qemu-recipes/grafana-plugins

# grafana_setup <shared dashboards dir in the guest>
grafana_setup() {
	local shared=$1

	printf '%s\n' grafana grafana-openrc >> "$tmp"/etc/apk/world

	mkdir -p "$tmp"/etc/conf.d
	makefile root:root 0644 "$tmp"/etc/conf.d/grafana <<-EOF
	GRAFANA_HOME=/var/lib/grafana
	GRAFANA_OPTS="-config /etc/grafana.ini -homepath /usr/share/grafana
	cfg:paths.data=\$GRAFANA_HOME/data
	cfg:paths.plugins=$GRAFANA_PLUGINS_DIR
	cfg:paths.provisioning=/etc/grafana/provisioning
	cfg:server.http_addr=0.0.0.0
	cfg:security.admin_user=$GRAFANA_ADMIN_USER
	cfg:security.admin_password=$GRAFANA_ADMIN_PASSWORD
	cfg:analytics.reporting_enabled=false
	cfg:analytics.check_for_updates=false
	cfg:analytics.check_for_plugin_updates=false
	cfg:news.news_feed_enabled=false
	cfg:plugins.preinstall_disabled=true
	cfg:log.mode=syslog"
	rc_need=logger
	EOF

	mkdir -p "$tmp"/etc/grafana/provisioning/datasources \
		"$tmp"/etc/grafana/provisioning/dashboards \
		"$tmp"/etc/grafana/provisioning/plugins \
		"$tmp"/etc/grafana/provisioning/alerting \
		"$tmp"$GRAFANA_PLUGINS_DIR
	makefile root:root 0644 "$tmp"/etc/grafana/provisioning/dashboards/qemu-recipes.yaml <<-EOF
	apiVersion: 1
	providers:
	  - name: qemu-recipes
	    folder: qemu-recipes
	    type: file
	    disableDeletion: true
	    allowUiUpdates: false
	    options:
	      path: /usr/share/qemu-recipes/dashboards
	  - name: shared
	    folder: Shared
	    type: file
	    updateIntervalSeconds: 10
	    allowUiUpdates: true
	    options:
	      path: $shared
	      foldersFromFilesStructure: false
	EOF

	mkdir -p "$tmp"/usr/share/qemu-recipes/dashboards
	grafana_node_dashboard > "$tmp"/usr/share/qemu-recipes/dashboards/vms-prometheus.json
	grafana_zabbix_dashboard > "$tmp"/usr/share/qemu-recipes/dashboards/vms-zabbix.json

	rc_add grafana default
}

# grafana_zabbix_plugin: bundle the Zabbix plugin (verified by its sha256
# from grafana.com) and enable it
grafana_zabbix_plugin() {
	local api=https://grafana.com/api/plugins/alexanderzobnin-zabbix-app meta ver sha256 zip
	zip="$tmp"/zabbix-plugin.zip

	makefile root:root 0644 "$tmp"/etc/grafana/provisioning/plugins/zabbix.yaml <<-'EOF'
	apiVersion: 1
	apps:
	  - type: alexanderzobnin-zabbix-app
	    org_id: 1
	    disabled: false
	EOF

	ver=$GRAFANA_ZABBIX_PLUGIN_VERSION
	if [ "$ver" = latest ]; then
		# pretty-printed JSON: the top-level key is indented by two spaces
		ver=$(wget -q -O - "$api" | sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' | head -n 1)
	fi
	if [ -n "$ver" ] \
		&& meta=$(wget -q -O - "$api/versions/$ver") \
		&& sha256=$(echo "$meta" | awk '/"linux-amd64": *\{/ { f = 1 } f && /"sha256"/ { print; exit }' \
			| sed -n 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/p') \
		&& [ -n "$sha256" ] \
		&& wget -q -O "$zip" "$api/versions/$ver/download?os=linux&arch=amd64" \
		&& echo "$sha256  $zip" | sha256sum -c >/dev/null \
		&& unzip -q -o "$zip" -d "$tmp"$GRAFANA_PLUGINS_DIR; then
		rm -f "$zip"
	else
		rm -f "$zip"
		echo "ERROR: could not bundle the Grafana Zabbix plugin ($ver)" >&2
		return 1
	fi
}

# Dashboard: the VMs as seen by Prometheus (node_exporter)
grafana_node_dashboard() {
	cat <<-'EOF'
	{
	  "uid": "qemu-recipes-vms-prometheus",
	  "title": "VMs (Prometheus)",
	  "tags": ["qemu-recipes"],
	  "schemaVersion": 39,
	  "time": { "from": "now-1h", "to": "now" },
	  "refresh": "30s",
	  "templating": { "list": [
	    { "name": "datasource", "label": "Prometheus", "type": "datasource",
	      "query": "prometheus" },
	    { "name": "instance", "label": "VM", "type": "query",
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "query": { "query": "label_values(node_uname_info, instance)", "refId": "vars" },
	      "refresh": 2, "multi": true, "includeAll": true,
	      "current": { "text": "All", "value": "$__all" } }
	  ] },
	  "panels": [
	    { "id": 1, "type": "table", "title": "VMs",
	      "gridPos": { "x": 0, "y": 0, "w": 24, "h": 7 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "targets": [ { "refId": "A", "instant": true, "format": "table",
	        "expr": "up{job=\"node\", instance=~\"$instance\"}" } ],
	      "transformations": [ { "id": "organize", "options": {
	        "excludeByName": { "Time": true, "__name__": true, "job": true },
	        "renameByName": { "Value": "up" } } } ] },
	    { "id": 2, "type": "timeseries", "title": "CPU busy",
	      "gridPos": { "x": 0, "y": 7, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}}",
	        "expr": "100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\", instance=~\"$instance\"}[$__rate_interval])))" } ] },
	    { "id": 3, "type": "timeseries", "title": "Memory used",
	      "gridPos": { "x": 12, "y": 7, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}}",
	        "expr": "100 * (1 - node_memory_MemAvailable_bytes{instance=~\"$instance\"} / node_memory_MemTotal_bytes{instance=~\"$instance\"})" } ] },
	    { "id": 4, "type": "timeseries", "title": "Load (1m)",
	      "gridPos": { "x": 0, "y": 15, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}}",
	        "expr": "node_load1{instance=~\"$instance\"}" } ] },
	    { "id": 5, "type": "timeseries", "title": "Root filesystem used (RAM)",
	      "gridPos": { "x": 12, "y": 15, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}}",
	        "expr": "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\", instance=~\"$instance\"} / node_filesystem_size_bytes{mountpoint=\"/\", instance=~\"$instance\"})" } ] },
	    { "id": 6, "type": "timeseries", "title": "Network received",
	      "gridPos": { "x": 0, "y": 23, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}} {{device}}",
	        "expr": "rate(node_network_receive_bytes_total{device!=\"lo\", instance=~\"$instance\"}[$__rate_interval])" } ] },
	    { "id": 7, "type": "timeseries", "title": "Network sent",
	      "gridPos": { "x": 12, "y": 23, "w": 12, "h": 8 },
	      "datasource": { "type": "prometheus", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
	      "targets": [ { "refId": "A", "legendFormat": "{{instance}} {{device}}",
	        "expr": "rate(node_network_transmit_bytes_total{device!=\"lo\", instance=~\"$instance\"}[$__rate_interval])" } ] }
	  ]
	}
	EOF
}

# Dashboard: the VMs as seen by Zabbix ("Linux by Zabbix agent" items)
grafana_zabbix_dashboard() {
	cat <<-'EOF'
	{
	  "uid": "qemu-recipes-vms-zabbix",
	  "title": "VMs (Zabbix)",
	  "tags": ["qemu-recipes"],
	  "schemaVersion": 39,
	  "time": { "from": "now-1h", "to": "now" },
	  "refresh": "1m",
	  "templating": { "list": [
	    { "name": "datasource", "label": "Zabbix", "type": "datasource",
	      "query": "alexanderzobnin-zabbix-datasource" }
	  ] },
	  "panels": [
	    { "id": 1, "type": "timeseries", "title": "CPU utilization",
	      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 9 },
	      "datasource": { "type": "alexanderzobnin-zabbix-datasource", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "percent", "min": 0 }, "overrides": [] },
	      "targets": [ { "refId": "A", "queryType": "0",
	        "group": { "filter": "/.*/" }, "host": { "filter": "/.*/" },
	        "itemTag": { "filter": "" }, "item": { "filter": "CPU utilization" },
	        "functions": [], "options": { "showDisabledItems": false } } ] },
	    { "id": 2, "type": "timeseries", "title": "Memory utilization",
	      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 9 },
	      "datasource": { "type": "alexanderzobnin-zabbix-datasource", "uid": "${datasource}" },
	      "fieldConfig": { "defaults": { "unit": "percent", "min": 0 }, "overrides": [] },
	      "targets": [ { "refId": "A", "queryType": "0",
	        "group": { "filter": "/.*/" }, "host": { "filter": "/.*/" },
	        "itemTag": { "filter": "" }, "item": { "filter": "Memory utilization" },
	        "functions": [], "options": { "showDisabledItems": false } } ] },
	    { "id": 3, "type": "timeseries", "title": "Load average (1m)",
	      "gridPos": { "x": 0, "y": 9, "w": 12, "h": 9 },
	      "datasource": { "type": "alexanderzobnin-zabbix-datasource", "uid": "${datasource}" },
	      "targets": [ { "refId": "A", "queryType": "0",
	        "group": { "filter": "/.*/" }, "host": { "filter": "/.*/" },
	        "itemTag": { "filter": "" }, "item": { "filter": "Load average (1m avg)" },
	        "functions": [], "options": { "showDisabledItems": false } } ] },
	    { "id": 4, "type": "timeseries", "title": "Zabbix agent availability",
	      "gridPos": { "x": 12, "y": 9, "w": 12, "h": 9 },
	      "datasource": { "type": "alexanderzobnin-zabbix-datasource", "uid": "${datasource}" },
	      "targets": [ { "refId": "A", "queryType": "0",
	        "group": { "filter": "/.*/" }, "host": { "filter": "/.*/" },
	        "itemTag": { "filter": "" }, "item": { "filter": "Zabbix agent availability" },
	        "functions": [], "options": { "showDisabledItems": false } } ] }
	  ]
	}
	EOF
}

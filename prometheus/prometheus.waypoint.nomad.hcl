variable "job_dcs" {
  description = ""
  default = {
    home = ["${nomad_region}"]
  }
}

variable "job_type" {
  description = ""
  default = "service"
}

variable "cluster_config_max" {
  description = ""
  default = {
    ops   = 1
  }
}

variable "cluster_config_min" {
  description = ""
  default = {
    ops   = 1
  }
}

locals {
  count_min    = lookup("$${var.cluster_config_min}", "${job_env}", 1)
  count_max    = lookup("$${var.cluster_config_max}", "${job_env}", 1)
}

job "prometheus" {
  name        = "prometheus"
  datacenters = ["${nomad_region}"]
  type        = "$${var.job_type}"
  namespace   = "${job_env}"
  //region      = "${nomad_region}"

  # TODO : interpolate and do dynamic block constraint delivery
  constraint {
    attribute = "$${meta.node-switcher}"
    value = "on"
  }

  constraint {
    attribute = "$${meta.purpose}"
    value = "worker"
  }

  ##TODO: Interpolate prod class while using ops namespace/job_env
  constraint {
    attribute = "$${node.class}"
    value = "prod"
  }

  constraint {
    operator  = "distinct_hosts"
    value     = "true"
  }



  group "prometheus" {
    count = local.count_max

    scaling {
      min = local.count_min
      max = local.count_max
    }

    volume "prometheus" {
      type    = "host"
      source = "prometheus"
      read_only = false
    }

    network {
      mode = "bridge"
      port "prometheus" {
        to = 9090
        static = 19090 #ToDo: convert this to dynamic port
      }
    }

    service {
      name = "prometheus-${job_env}"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.prometheus-https.rule=Host(`${traefik_url}`)",
        "traefik.http.routers.prometheus-https.entrypoints=websecure",
        "traefik.http.routers.prometheus-https.service=prometheus@consulcatalog",
        "traefik.http.routers.prometheus-https.tls=false",
        "traefik.http.services.prometheus.loadbalancer.server.scheme=http",
      ]
      port = "prometheus"
      
      check {
        name = "ready"
        type = "http"
        path = "/-/ready"
        interval = "10s"
        timeout = "2s"
        //expose = true
      }

      check {
        name = "alive"
        type = "http"
        path = "/-/healthy"
        interval = "10s"
        timeout = "2s"
        //expose = true
      }
    }

    task "prometheus" {
      driver = "docker"
      user = "1000"
      config {
        image = "${artifact.image}:${artifact.tag}"
        auth {
          username = "${docker_username}"
          password = "${docker_password}"
        }
        ports = [
          "prometheus"
        ]
        volumes = [
          "local/prometheus.yml:/etc/prometheus/prometheus.yml",
          "local/alert.rules.yml:/etc/prometheus/alert.rules.yml"
        ]
        args = [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.retention.time=183d",
          "--web.enable-lifecycle",
          "--enable-feature=new-service-discovery-manager",
          "--web.enable-admin-api"
        ]
      }

      volume_mount {
        volume      = "prometheus"
        destination = "/prometheus"
      }

      resources {
        cpu = 1024
        memory = 384
      }

      vault {
        policies = ["prometheus-telemetry"]
        change_mode   = "signal"
        change_signal = "SIGHUP"
        env = true
      }

      env {
        %{ for k,v in entrypoint.env ~}
        ${k} = "${v}"
        %{ endfor ~}
        WAYPOINT_LOG_LEVEL = "DEBUG"
      }

      ## TODO: Get Consul scrapers working with Consul cluster address
      ## TODO: Interpolate SNMP IPs by data center
      template {
        change_mode = "noop"
        destination   = "local/prometheus.yml"
        data = <<EOH
---
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    cluster: aws1
    __replica__: {{ env "NOMAD_ALLOC_NAME" }}.{{ env "NOMAD_ALLOC_ID" }}

alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - alertmanager-ops.service.aws1.consul:9093


rule_files:
  - "alert.rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets:
        - 127.0.0.1:9090
    scrape_interval: 15s

  - job_name: 'traefik'
    consul_sd_configs:
    - server: '127.0.0.1:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['traefik-ops']

    relabel_configs:
    - source_labels: ['__meta_consul_node']
      action: replace
      target_label : 'instance'



  - job_name: 'prometheus-monitor'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['prometheus-monitor-ops']

    relabel_configs:
    - source_labels: ['__meta_consul_node']
      action: replace
      target_label : 'instance'

  - job_name: 'alertmanager'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['alertmanager-ops']

    relabel_configs:
    - source_labels: ['__meta_consul_node']
      action: replace
      target_label : 'instance'

  - job_name: 'grafana'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['grafana-ops']

    relabel_configs:
    - source_labels: ['__meta_consul_node']
      action: replace
      target_label : 'instance'

  - job_name: 'nomad_client_metrics'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['nomad-client']

    relabel_configs:
      - source_labels: ['__meta_consul_node']
        action: replace
        target_label : 'instance'

    scrape_interval: 15s
    metrics_path: /v1/metrics
    params:
      format: ['prometheus']

  - job_name: 'nomad_server_metrics'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['nomad']
      tags: ['http']

    relabel_configs:
      - source_labels: ['__meta_consul_node']
        action: replace
        target_label : 'instance'

    scrape_interval: 15s
    metrics_path: /v1/metrics
    params:
      format: ['prometheus']


  - job_name: 'node-exporter'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['node-exporter']
    scrape_interval: 15s
    metrics_path: /metrics
    params:
      format: ['prometheus']

    relabel_configs:
    - source_labels: ['__meta_consul_node']
      action: replace
      target_label : 'instance'


  - job_name: 'consul-exporter'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['consul-exporter-prod']
    scrape_interval: 15s
    metrics_path: /metrics
    params:
      format: ['prometheus']

    relabel_configs:
      - source_labels: ['__meta_consul_node']
        action: replace
        target_label : 'instance'


  - job_name: 'vault'
    consul_sd_configs:
    - server: 'consul.service.consul:8500'
      token: '{{ with secret "consul/creds/prometheus"}}{{ .Data.token }}{{ end }}'
      services: ['vault']
      tags: ['active']
    metrics_path: "/v1/sys/metrics"
    params:
      format: ['prometheus']
    scheme: https
    tls_config:
      insecure_skip_verify: true
    bearer_token: '{{ env "VAULT_TOKEN" }}'

    relabel_configs:
      - source_labels: ['__meta_consul_node']
        action: replace
        target_label : 'instance'




EOH
      }

      template {
        change_mode = "noop"
        destination = "local/alert.rules.yml"
        left_delimiter = "{{{"
        right_delimiter = "}}}"
        data = <<EOH
---
groups:
  - name: Node Down Alerts
    rules:
      - alert: 25% Nodes down
        expr: count(up{job="node-exporter"}==0)/count(up{job="node-exporter"}==1)*100 > 25
        for: 10m
        labels:
          severity: critical
        annotations:
          description: "Over 25% of all production nodes are down for the past 10 minutes"

      - alert: 20% Nodes down
        expr: count(up{job="node-exporter"}==0)/count(up{job="node-exporter"}==1)*100 > 20
        for: 10m
        labels:
          severity: warning
        annotations:
          description: "Over 20% of all production nodes are down for the past 10 minutes"

      - alert: 10% Nodes down
        expr: count(up{job="node-exporter"}==0)/count(up{job="node-exporter"}==1)*100 > 10
        for: 10m
        labels:
          severity: Info
        annotations:
          description: "Over 10% of all production nodes are down for the past 10 minutes"

  - name: File System Alerts
    rules:
      - alert: File system 90% full
        expr: (node_filesystem_avail_bytes{job="node-exporter"} * 100) / node_filesystem_size_bytes{job="node-exporter"} < 10 and ON (instance, device, mountpoint) node_filesystem_readonly {job="node-exporter"} == 0
        for: 5m
        labels:
          severity: info
        annotations:
          summary: Disk usage is critically high
          description: "Disk space is over 90% used"

      - alert: File system 80% full
        expr: (node_filesystem_avail_bytes{job="node-exporter"} * 100) / node_filesystem_size_bytes{job="node-exporter"} < 20 and ON (instance, device, mountpoint) node_filesystem_readonly {job="node-exporter"} == 0
        for: 5m
        labels:
          severity: info
        annotations:
          summary: Disk usage is very high
          description: "Disk space is over 80% used"

      - alert: File system 75% full
        expr: (node_filesystem_avail_bytes{job="node-exporter"} * 100) / node_filesystem_size_bytes{job="node-exporter"} < 25 and ON (instance, device, mountpoint) node_filesystem_readonly {job="node-exporter"} == 0
        for: 2m
        labels:
          severity: info
        annotations:
          summary: Disk usage is high
          description: "Disk space is over 75% used on {{ $labels.instance }}:{{ $value }}% disk free"

  - name: CPU Alerts
    rules:
      - alert: CPU Critical
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle", job="node-exporter"}[2m])) * 100) > 90
        for: 5m
        labels:
          severity: info
        annotations:
          summary: Host high CPU load (instance {{ $labels.instance }})
          description: "CPU load is > 90%\n  VALUE = {{ $value }}\n  LABELS = {{ $labels }}"

      - alert: CPU Very High
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle", job="node-exporter"}[2m])) * 100) > 80
        for: 5m
        labels:
          severity: info
        annotations:
          summary: Host high CPU load (instance {{ $labels.instance }})
          description: "CPU load is > 80%\n  VALUE = {{ $value }}\n  LABELS = {{ $labels }}"

      - alert: CPU High
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle", job="node-exporter"}[2m])) * 100) > 75
        for: 2m
        labels:
          severity: info
        annotations:
          summary: Host high CPU load (instance {{ $labels.instance }})
          description: "CPU load is > 75% on {{ $labels.instance }}:{{ $value }}%"

  - name: Memory Alerts
    rules:
      - alert: Node OOM
        expr: node_memory_MemAvailable_bytes{job="node-exporter"} / node_memory_MemTotal_bytes{job="node-exporter"} * 100 < 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: Node out of memory
          description: Node memory is filling up over 90%

  

  - name: Nomad Alerts
    rules:
      - alert: Nomad job failure
        expr: delta(nomad_nomad_job_summary_failed{job="nomad_server_metrics", namespace="prod"}[5m]) > 0
        for: 1m
        labels:
          severity: info
        annotations:
          summary: Nomad job failed (instance {{ $labels.instance }})
          description: "Nomad job failed\n  VALUE = {{ $value }}\n  LABELS = {{ $labels }}"

      #TODO: Use Consul Exporter for this alert
      - alert: Nomad Client is down
        expr: up{job="nomad_client_metrics"} == 0
        for: 2m
        labels:
          severity: info
        annotations:
          summary: Nomad Client is down on {{ $labels.instance }}
          description: Nomad Client is down on {{ $labels.instance }}

  - name: Consul Alerts
    rules:
      - alert: No Consul cluster leader
        expr: consul_raft_leader < 1
        for: 1m
        labels:
          severity: info
        annotations:
          summary: Consul cluster has no leader
          description: Consul cluster has no leader

  - name: Vault Alerts
    rules:
      - alert: Vault is Sealed
        expr: vault_core_unsealed == 0
        for: 5m
        labels:
          severity: info
        annotations:
          summary: Vault is sealed
          description: Vault is sealed and no clients will be able to access it

      - alert: Vault lease creation spike
        expr: delta(vault_expire_num_leases[1h]) > 500
        for: 1m
        labels:
          severity: info
        annotations:
          summary: Over 500 leases have been created in Vault in the last hour
          description: Over 500 leases have been created in Vault in the last hour

EOH
      }
    }
  }
}

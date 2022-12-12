job "node-exporter" {
  name        = "node-exporter"
  datacenters = [ "${nomad_region}" ]
  type        = "system"
  namespace   = "ops"

  constraint {
    attribute = "$${meta.node-switcher}"
    value = "on"
  }

  constraint {
    operator  = "distinct_hosts"
    value     = "true"
  }

  group "node-exporter" {
    network {
      port "exporter" {
        to = 9100
      }
    }

    service {
      name = "node-exporter-prod"
      port = "exporter"
    }

    task "node-exporter" {
      # TODO : interpolate driver
      driver = "docker"
      user = "1000"
      config {
        image = "${artifact.image}:${artifact.tag}"
        auth {
          username = "${docker_username}"
          password = "${docker_password}"
        }
        ports = [
          "exporter"
        ]
      }

      resources {
        cpu = 100
        memory = 64
      }
    }
  }
}

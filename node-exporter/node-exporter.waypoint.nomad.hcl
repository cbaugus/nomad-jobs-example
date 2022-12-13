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
      name = "node-exporter-prod" # TODO : update thie to an env var
      port = "exporter"
    }

    task "node-exporter" {
      driver = "docker"
      user = "1000"
      config {
        image = "${artifact.image}:${artifact.tag}"
        auth {
          username = "${docker_username}" # TODO : change to use VAULT creds
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

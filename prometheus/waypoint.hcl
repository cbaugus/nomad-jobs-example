project = "prometheus"

app "prometheus" {
  build {
    use "docker" {
      dockerfile = templatefile("${path.app}/Dockerfile", {
        tag = var.build_image_tag
      })
    }
    registry {
      use "docker" {
        image        = "${docker_name}/${app.name}"
        tag          = var.build_image_tag
        auth {
          username = var.docker_user
          password = var.docker_password
        }
      }
    }
  }

  deploy {
    use "nomad-jobspec" {
      jobspec = templatefile("${path.app}/${app.name}.waypoint.nomad.hcl", {
        job_env         = "${workspace.name}"
        docker_username = var.docker_user
        docker_password = var.docker_password
        nomad_region    = var.nomad_region
        traefik_url     = var.traefik_url
      })
    }
  }
}

variable "build_image_tag" {
  type    = string
  default = ""
}

variable "docker_name" {
  type    = string
  default = ""
}

variable "docker_user" {
  type    = string
  default = ""
}

variable "docker_password" {
  type    = string
  default = ""
}

variable "nomad_region" {
  type    = string
  default = ""
}

variable "traefik_url" {
  type    = string
  default = ""
}

consul {
  address = "consul:8500"

  retry {
    enabled  = true
    attempts = 12
    backoff  = "250ms"
  }
}
template {
  source      = "/etc/nginx/conf.d/proxy.conf.ctmpl"
  destination = "/etc/nginx/conf.d/proxy.conf"
  perms       = 0600
  command = "/etc/init.d/nginx reload"
  command_timeout = "60s"
}

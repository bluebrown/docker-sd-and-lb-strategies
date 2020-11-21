# Docker Networking 101 - Service Discovery and Loadbalancing 

A common question that arises is how does service discovery in docker work. And how does docker route the traffic.
This project showcases some strategies for service discovery with docker and docker-compose. 

Before we dive into more advanced strategies, lets review some of the basics.

## Docker's built-in Nameserver & Loadbalancer

Docker comes with a built-in [nameserver][1]. The server is, by default, reachable via `127.0.0.11:53`.

Every container has by default a nameserver entry in `/etc/resolve.conf`, so it is not required to specify the address of the nameserver from within the container. That is why you can find your service from within the network with `service` or `task_service_n`. 

If you do `task_service_n` then you will get the address of the corresponding service replica.

If you only ask for the `service` docker will perform `internal load balancing` between container in the same network and `external load balancing` to handle requests from outside. 

When swarm is used, docker will additionally use an two special [overloay networks][2]. It will use an `ingress network` on each host which handled trafic to the swarm and allows to query any service from any node in the swarm. Additionally it will create a bridge network called `docker_gwbridge` which connected the individual docker hosts and their overloay networks (including ingress).

  [1]: https://docs.docker.com/config/containers/container-networking/#dns-services
  [2]: https://docs.docker.com/network/overlay/

## Example

For example deploy three replicas from *dig/docker-compose.yml*

```yml
version: '3.8'
services:
  whoami:
    image: "traefik/whoami"
    deploy:
      replicas: 3
```

### DNS Lookup

You can use tools such as `dig` or `nslookup` to do a DNS lookup against the nameserver in the *same network*.

```shell
docker run --rm --network dig_default tutum/dnsutils dig whoami
```

```shell
; <<>> DiG 9.9.5-3ubuntu0.2-Ubuntu <<>> whoami
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 58433
;; flags: qr rd ra; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 0

;; QUESTION SECTION:
;whoami.                                IN      A

;; ANSWER SECTION:
whoami.                 600     IN      A       172.28.0.3
whoami.                 600     IN      A       172.28.0.2
whoami.                 600     IN      A       172.28.0.4

;; Query time: 0 msec
;; SERVER: 127.0.0.11#53(127.0.0.11)
;; WHEN: Mon Nov 16 22:36:37 UTC 2020
;; MSG SIZE  rcvd: 90
```

If you are only interested in the IP, you can provide the `+short` option

```shell
docker run --rm --network dig_default tutum/dnsutils dig +short whoami
```

```shell
172.28.0.3
172.28.0.4
172.28.0.2
```

Or look for specific service
```shell
docker run --rm --network dig_default tutum/dnsutils dig +short dig_whoami_2
```

```shell
172.28.0.4
```

### Load balancing

The default loadbalancing happens on the transport layer or layer 4 of the OSI model. So it is TCP/UDP based. So it is not possible to inpsect and manipulate http headers with this method. In the enterprise edition it is apparently possible to use labels similar to the ones treafik is using in the example a bit further down.


  [3]: https://blog.octo.com/en/how-does-it-work-docker-part-3-load-balancing-service-discovery-and-security/

```
docker run --rm --network dig_default curlimages/curl -Ls http://whoami
```

```shell
Hostname: eedc94d45bf4
IP: 127.0.0.1
IP: 172.28.0.3
RemoteAddr: 172.28.0.5:43910
GET / HTTP/1.1
Host: whoami
User-Agent: curl/7.73.0-DEV
Accept: */*
```

Here is the hostname from 10 times curl:

```
Hostname: eedc94d45bf4
Hostname: 42312c03a825
Hostname: 42312c03a825
Hostname: 42312c03a825
Hostname: eedc94d45bf4
Hostname: d922d86eccc6
Hostname: d922d86eccc6
Hostname: eedc94d45bf4
Hostname: 42312c03a825
Hostname: d922d86eccc6
```

## Health Checks

Health checks, by default, are done by checking the process id (PID) of the container on the host kernel. If the process is running successfully, the container is considered healthy. 

Oftentimes other health checks are required. The container may be running but the application inside has crashed. In many cases a TCP or HTTP check is preferred. 

It is possible to bake a custom health checks into images.

```Dockerfile
FROM traefik/whoami
HEALTHCHECK CMD curl --fail http://localhost || exit 1   
```

It is also possible to specify the health check via cli when starting the container.

```shell
docker run \
  --health-cmd "curl --fail http://localhost || exit 1" \
  --health-interval=5s \
  --timeout=3s \
  traefik/whoami
```


## Service Discovery & Loadbalancing Strategies

If the built in features are not sufficent, some strategies can be implemented to achieve better control. Below are some examples.


### HAProxy

Haproxy can use the docker nameserver in combination with dynamic server templates to discover the running container. Then the traditional proxy features can be leveraged to achieve powerful layer 7 load balancing whith http header manipulation and chaos engeering such as retries.

```yml
version: '3.8'
services:

  loadbalancer:
    image: haproxy
    volumes: 
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - 80:80
      - 443:443
  
  whoami:
    image: "traefik/whoami"
    deploy:
      replicas: 3
```

```conf
...
resolvers docker
    nameserver dns1 127.0.0.11:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry   1s
    hold other      10s
    hold refused    10s
    hold nx         10s
    hold timeout    10s
    hold valid      10s
    hold obsolete   10s
...
backend whoami
    balance leastconn
    option httpchk
    option redispatch 1
    retry-on all-retryable-errors
    retries 2
    http-request disable-l7-retry if METH_POST
    dynamic-cookie-key MY_SERVICES_HASHED_ADDRESS
    cookie MY_SERVICES_HASHED_ADDRESS insert dynamic
    server-template whoami- 6 whoami:80 check resolvers docker init-addr libc,none
...
```

### Traefik

The previous method is already pretty decent. However, you may have noticed that it requires knowing which services should be discovered
and also the number of replicas to discover is hard coded. Traefik, a container native edge router, solves both problems. As long as we enable
Traefik via label, the service will be discovered. This decentralized the configuration. It is as if each service registers itself. 
The label can also be used to inspect and manipulate http headers.

```yml
version: "3.8"

services:
  traefik:
    image: "traefik:v2.3"
    command:
      - "--log.level=DEBUG"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"

  whoami:
    image: "traefik/whoami"
    labels:
      - "traefik.enable=true"
      - "traefik.port=80"
      - "traefik.http.routers.whoami.entrypoints=web"
      - "traefik.http.routers.whoami.rule=PathPrefix(`/`)"
      - "traefik.http.services.whoami.loadbalancer.sticky=true"
      - "traefik.http.services.whoami.loadbalancer.sticky.cookie.name=MY_SERVICE_ADDRESS"
    deploy:
      replicas: 3

```

### Consul

Consul is a tool for service discovery and configuration management. Services have to be registered via API request. It is a more complex solution that probably only makes sense in bigger clusters, but can be very powerful. Usually it recommended running this on bare metal and not in a container. You could install it alongside, the docker host on each server in your cluster. 

In this example it has been paired with the registrator image, which takes care of registering the docker services in consuls catalog. 
The catalog can be leveraged in many ways. One of the is to use consul-template. Note that consul comes with its own DNS resolver so in this instance the docker DNS resolver is somewhat neglected.

```yml
version: '3.8'
services:

  consul:
    image:  gliderlabs/consul-server:latest
    command: "-advertise=${MYHOST} -server -bootstrap"
    container_name: consul
    hostname: ${MYHOST}
    ports:
    - 8500:8500

  registrator:
    image: gliderlabs/registrator:latest
    command: "-ip ${MYHOST} consul://${MYHOST}:8500"
    container_name: registrator
    hostname: ${MYHOST}
    depends_on:
    - consul
    volumes:
    - /var/run/docker.sock:/tmp/docker.sock

  proxy:
    build: .
    ports:
      - 80:80
    depends_on: 
      - consul

  whoami:
    image: "traefik/whoami"
    deploy:
      replicas: 3
    ports:
      - "80"

```

Consul template takes a template file and rendered it according to the content of consuls catalog. 

```conf
upstream whoami {
{{ range service "whoami" }}
  server {{ .Address }}:{{ .Port }};
{{ end }}
}

server {
   listen 80;
   location / {
      proxy_pass http://whoami;
   }
}
```

After the template has been changed, the restart command is performed.

```conf
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
```


## Conclusion

There are many ways to go about it. Below are a few example options. Of course there are more tools out there and other combinations possible. I have shown how the built in features work and also show cased some advanced strategies to do service discovery and loadbalancing. Below is a feature table of these examples.

|                   | Built In  | HAProxy          | Traefik      | Consul-Template        |
|-------------------|-----------|------------------|--------------|------------------------|
| Resolver          | Docker    | Docker           | Docker       | Consul                 |
| Service Discovery | Automatic | Server Templates | Label System | KV Store + Template    |
| Health Checks     | Yes       | Yes              | Yes          | Yes                    |
| Load Balancing    | L4        | L4, L7           | L4, L7       | L4, L7                 |
| Sticky Session    | Yes       | Yes              | Yes          | Depends on proxy       |
| Metrics           | No        | Stats Page       | Dashboard    | Dashboard              |

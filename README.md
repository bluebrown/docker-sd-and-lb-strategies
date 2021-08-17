# Docker & Docker Swarm Service Discovery

## Docker's built-in Nameserver & Loadbalancer

Docker comes with a built-in [nameserver](https://docs.docker.com/config/containers/container-networking/#dns-services). The server is, by default, reachable via `127.0.0.11:53`.

Every container has by default a nameserver entry in `/etc/resolv.conf`, so it is not required to specify the address of the nameserver from within the container. That is why you can find your service from within the network with `service` or `task_service_n`. 

If you do `task_service_n` then you will get the address of the corresponding service replica.

If you only ask for the `service` docker will perform `internal load balancing` between container in the same network and `external load balancing` to handle requests from outside. 

When swarm is used, docker will additionally use two special networks. 
1. The `ingress network`, which is actually an [overlay network](https://docs.docker.com/network/overlay/) and handles incomming trafic to the swarm. It allows to query any service from any node in the swarm. 
2. The `docker_gwbridge`, a [bridge network](https://docs.docker.com/network/bridge/), which connects the overlay networks of the individual hosts to an their physical network. (including ingress)

When using swarm to [deploy services](https://docs.docker.com/compose/compose-file/compose-file-v3/#deploy), the  behavior as described in the examples below will not work unless endpointmode is set to dns roundrobin instead of vip.

> endpoint_mode: vip - Docker assigns the service a virtual IP (VIP) that acts as the front end for clients to reach the service on a network. Docker routes requests between the client and available worker nodes for the service, without client knowledge of how many nodes are participating in the service or their IP addresses or ports. (This is the default.)

> endpoint_mode: dnsrr - DNS round-robin (DNSRR) service discovery does not use a single virtual IP. Docker sets up DNS entries for the service such that a DNS query for the service name returns a list of IP addresses, and the client connects directly to one of these. DNS round-robin is useful in cases where you want to use your own load balancer, or for Hybrid Windows and Linux applications.

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

You can use tools such as [dig](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/6/html/deployment_guide/s2-bind-dig) or [nslookup](https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/nslookup) to do a DNS lookup against the nameserver in the *same network*.

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

The default loadbalancing happens on the transport layer or layer 4 of the [OSI Model](https://www.cloudflare.com/learning/ddos/glossary/open-systems-interconnection-model-osi/). So it is TCP/UDP based. That means it is not possible to inpsect and manipulate http headers with this method. In the enterprise edition it is apparently possible to use labels similar to the ones treafik is using in the example a bit further down.


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

[Health checks](https://docs.docker.com/engine/reference/builder/#healthcheck), by default, are done by checking the process id (PID) of the container on the host kernel. If the process is running successfully, the container is considered healthy. 

Oftentimes other health checks are required. The container may be running but the application inside has crashed. In many cases a TCP or HTTP check is preferred. 

It is possible to bake a custom health checks into images. For example, using [curl](https://curl.se/docs/manual.html) to perform L7 health checks.

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

## Example with Swarm

As initially mentioned, swarms behavior is different in that it will assign a virtual IP to services by default. Its actually not different its just docker or docker-compose doesn't create real services, it just imitates the behavior of swarm but still runs the container normally, as services can, in fact, only be created by manager nodes.

Keeping in mind we are on a swarm manager and thus the default mode is VIP

Create a overlay network that can be used by regular containers too

```bash
$ docker network create --driver overlay --attachable testnet
```

create some service with 2 replicas

```bash 
$ docker service create --network testnet --replicas 2 --name digme nginx
```

Now lets use dig again and making sure we attach the container to the same network

```
$ docker run --network testnet --rm tutum/dnsutils dig  digme
digme.                  600     IN      A       10.0.18.6
```

We see that indeed we only got one IP address back, so it appears that this is the virtual IP that has been assigned by docker. 

Swarm allows actually to get the single IPs in this case **without** explicitly setting the endpoint mode. 

We can query for `tasks.<servicename>` in this case that is `tasks.digme`

```bash
$ docker run --network testnet --rm tutum/dnsutils dig tasks.digme
tasks.digme.            600     IN      A       10.0.18.7
tasks.digme.            600     IN      A       10.0.18.8
```

This has brought us 2 A records pointing to the individual replicas.

Now lets create another service with endpointmode set to dns roundrobin

```bash
docker service create --endpoint-mode dnsrr --network testnet --replicas 2 --name digme2 nginx
```

```bash
$ docker run --network testnet --rm tutum/dnsutils dig digme2
digme2.                 600     IN      A       10.0.18.21
digme2.                 600     IN      A       10.0.18.20
```

This way we get both IPs without adding the prefix `tasks`.

## Service Discovery & Loadbalancing Strategies

If the built in features are not sufficent, some strategies can be implemented to achieve better control. Below are some examples.

### HAProxy

[Haproxy](https://www.haproxy.com/) can use the docker nameserver in combination with [dynamic server templates](https://www.haproxy.com/blog/whats-new-haproxy-1-8/#server-template-configuration-directive) to discover the running container. Then the traditional proxy features can be leveraged to achieve powerful layer 7 load balancing with http header manipulation and [chaos engeering](https://www.haproxy.com/blog/haproxy-layer-7-retries-and-chaos-engineering/) such as retries.

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

The previous method is already pretty decent. However, you may have noticed that it requires knowing which services should be discovered and also the number of replicas to discover is hard coded. [Traefik](https://traefik.io/), a container native edge router, solves both problems. As long as we enable Traefik via [label](https://doc.traefik.io/traefik/v1.4/configuration/backends/docker/#labels-overriding-default-behaviour), the service will be discovered. This decentralized the configuration. It is as if each service registers itself. 

The label can also be used to [inspect and manipulate http headers](https://doc.traefik.io/traefik/middlewares/headers/).

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

[Consul](https://www.consul.io/) is a tool for service discovery and configuration management. Services have to be registered via API request. It is a more complex solution that probably only makes sense in bigger clusters, but can be very powerful. Usually it recommended running this on bare metal and not in a container. You could install it alongside the docker host on each server in your cluster. 

In this example it has been paired with the [registrator image](https://github.com/gliderlabs/registrator), which takes care of registering the docker services in consuls catalog. 

The catalog can be leveraged in many ways. One of them is to use [consul-template](https://github.com/hashicorp/consul-template). 

Note that consul comes with its own DNS resolver so in this instance the docker DNS resolver is somewhat neglected.

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

Dockerfile for custom proxy image with consul template backed in.
```Dockerfile
FROM nginx

RUN curl https://releases.hashicorp.com/consul-template/0.25.1/consul-template_0.25.1_linux_amd64.tgz \
  > consul-template_0.25.1_linux_amd64.tgz

RUN gunzip -c consul-template_0.25.1_linux_amd64.tgz | tar xvf -

RUN mv consul-template /usr/sbin/consul-template
RUN rm /etc/nginx/conf.d/default.conf
ADD proxy.conf.ctmpl /etc/nginx/conf.d/
ADD consul-template.hcl /

CMD [ "/bin/bash", "-c", "/etc/init.d/nginx start && consul-template -config=consul-template.hcl" ]
```

Consul template takes a template file and renders it according to the content of consuls catalog. 

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

After the template has been changed, the restart command is executed.

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


## Feature Table


|                   | Built In  | HAProxy          | Traefik      | Consul-Template        |
|-------------------|-----------|------------------|--------------|------------------------|
| Resolver          | Docker    | Docker           | Docker       | Consul                 |
| Service Discovery | Automatic | Server Templates | Label System | KV Store + Template    |
| Health Checks     | Yes       | Yes              | Yes          | Yes                    |
| Load Balancing    | L4        | L4, L7           | L4, L7       | L4, L7                 |
| Sticky Session    | No        | Yes              | Yes          | Depends on proxy       |
| Metrics           | No        | Stats Page       | Dashboard    | Dashboard              |

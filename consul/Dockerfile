FROM nginx

RUN curl https://releases.hashicorp.com/consul-template/0.25.1/consul-template_0.25.1_linux_amd64.tgz \
  > consul-template_0.25.1_linux_amd64.tgz

RUN gunzip -c consul-template_0.25.1_linux_amd64.tgz | tar xvf -

RUN mv consul-template /usr/sbin/consul-template
RUN rm /etc/nginx/conf.d/default.conf
ADD proxy.conf.ctmpl /etc/nginx/conf.d/
ADD consul-template.hcl /

CMD [ "/bin/bash", "-c", "/etc/init.d/nginx start && consul-template -config=consul-template.hcl" ]
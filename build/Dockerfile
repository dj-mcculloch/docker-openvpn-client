FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    bind-tools \
    curl \
    iptables \
    ip6tables \
    openvpn

COPY . /usr/local/bin

ENV KILL_SWITCH=on

ENTRYPOINT [ "entrypoint.sh" ]

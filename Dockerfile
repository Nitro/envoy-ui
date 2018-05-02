# ------------------------------------------------------------------------------
# Crystal Build Container
# ------------------------------------------------------------------------------
FROM alpine:3.7 as build_stage

RUN wget http://public.portalier.com/alpine/julien@portalier.com-56dab02e.rsa.pub -O /etc/apk/keys/julien@portalier.com-56dab02e.rsa.pub
RUN echo http://public.portalier.com/alpine/testing >> /etc/apk/repositories
RUN apk update && apk add crystal gcc shards openssl-dev

RUN mkdir /build
WORKDIR /build

ADD envoy-ui.cr clusters.ecr stats.ecr /build/

RUN crystal build --release envoy-ui.cr

# ------------------------------------------------------------------------------
# Production Container
# ------------------------------------------------------------------------------
FROM alpine:3.7
RUN apk update && apk add openssl-dev gc curl libgcc libevent pcre

RUN cd / && curl -L https://github.com/just-containers/skaware/releases/download/v1.21.2/s6-2.6.1.1-linux-amd64-bin.tar.gz | tar -xvzf -
ADD s6 /etc
COPY --from=build_stage /build/envoy-ui /envoy-ui/envoy-ui

CMD ["/bin/s6-svscan", "/etc/services"]

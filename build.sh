#!/bin/sh -e

TAG=$(git rev-parse --short HEAD)
docker build -t gonitro/envoy-ui:${TAG} .

# The reference application's image: nginx answering /api/health. It proves
# what the contract asks of a Project once `project new` has run, and it is
# meant to be replaced by whatever this Project turns out to be.
#
# Two stages, because the contract's `multi-stage-dockerfiles` rule requires
# them, and the first one earns its place. It renders the configuration with
# a stand-in release and asks nginx whether the result is valid, so a broken
# template fails the image build instead of the container start. The second
# stage takes only the template from it.
#
# The production image is this file's **last** stage. build.yml builds that
# one, whatever `target:` docker-compose.yml names.
#
# **It runs as a user that is not root** (decision 71), and test.yml fails
# the pull request of an image that does not: it reads the image's last
# `USER`. nginx-unprivileged declares `USER 101` (nginx) and listens on 8080,
# since a port under 1024 needs root. Its own default.conf, its pid file in
# /tmp and the entrypoint that renders /etc/nginx/templates are all made for
# that user. Not the stock nginx with a `USER` added: its master process
# expects root, to bind 80 and to write under /var.

FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24 AS config
COPY default.conf.template /etc/nginx/templates/default.conf.template
RUN RELEASE=config-check envsubst '${RELEASE}' \
      < /etc/nginx/templates/default.conf.template \
      > /etc/nginx/conf.d/default.conf \
 && nginx -t

FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24
# >>> addon:database
# The Postgres client, for the `migrate` and `seed` commands platform.json
# declares in this Service. They are connection checks here, and they run in
# this image as `sh -c '<command>'` (CONTRACT.md, "How the commands are run").
# Pinned to the major of the platform's engine.
#
# `apk add` needs root, so root for this line only, and the image's own user
# back after it: the last `USER` is the one the container runs as.
USER root
RUN apk add --no-cache postgresql17-client
USER 101
# <<< addon:database
COPY --from=config /etc/nginx/templates/default.conf.template /etc/nginx/templates/default.conf.template
# What /api/health reports when nothing says otherwise. The deploy always says
# otherwise: docker-compose.prod.yml passes the release tag.
ENV RELEASE=unknown

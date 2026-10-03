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

FROM nginx:1.30.5-alpine3.24 AS config
COPY default.conf.template /etc/nginx/templates/default.conf.template
RUN RELEASE=config-check envsubst '${RELEASE}' \
      < /etc/nginx/templates/default.conf.template \
      > /etc/nginx/conf.d/default.conf \
 && nginx -t

FROM nginx:1.30.5-alpine3.24
# >>> addon:database
# The Postgres client, for the `migrate` and `seed` commands platform.json
# declares in this Service. They are connection checks here, and they run in
# this image as `sh -c '<command>'` (CONTRACT.md, "How the commands are run").
# Pinned to the major of the platform's engine.
RUN apk add --no-cache postgresql17-client
# <<< addon:database
COPY --from=config /etc/nginx/templates/default.conf.template /etc/nginx/templates/default.conf.template
# What /api/health reports when nothing says otherwise. The deploy always says
# otherwise: docker-compose.prod.yml passes the release tag.
ENV RELEASE=unknown

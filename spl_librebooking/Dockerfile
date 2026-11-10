# SPL Equipment Booking: LibreBooking's official image plus Home Assistant start-up.
# The image is multi-architecture (amd64, arm64). Tags follow LibreBooking releases
# (https://hub.docker.com/r/librebooking/librebooking/tags). To update LibreBooking, change the tag
# here, bump the add-on version, and rebuild; the add-on applies database upgrades on start.
FROM librebooking/librebooking:7.2.0

ARG BUILD_VERSION=dev
LABEL io.hass.type="addon" io.hass.version="${BUILD_VERSION}" \
      org.opencontainers.image.title="SPL Equipment Booking" \
      org.opencontainers.image.description="LibreBooking as a Home Assistant add-on"

USER root

# jq reads the add-on options; the MariaDB client creates the database and user.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# The image keeps its job schedule in /config, which the add-on config folder replaces.
RUN mkdir -p /opt/spl && cp /config/lb-jobs-cron /opt/spl/lb-jobs-cron

COPY rootfs/ /
# Strip Windows line endings in case the files were checked out on Windows with CRLF.
RUN sed -i 's/\r$//' /opt/spl/run.sh /opt/spl/lb-db.php && chmod 0755 /opt/spl/run.sh

WORKDIR /var/www/html
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/Web/ || exit 1
ENTRYPOINT ["/opt/spl/run.sh"]
CMD []

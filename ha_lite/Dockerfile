ARG BUILD_FROM
FROM ${BUILD_FROM}
RUN apk add --no-cache docker-cli util-linux-misc
COPY rootfs/ /
RUN chmod +x /run.sh /ha-lite/host/*.sh
CMD ["/run.sh"]

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS build

RUN apk add --no-cache build-base linux-headers perl curl gnupg xz
COPY release-key.asc /tmp/release-key.asc
WORKDIR /src
# Official release archive, authenticated with the upstream release signing key.
# gpgv, not gpg: it starts no agent or keybox daemon, so the layer needs no
# `gpgconf --kill all` (which failed intermittently in CI) and cannot hang.
RUN curl -fsSLO https://github.com/squid-cache/squid/releases/download/SQUID_7_7/squid-7.7.tar.xz \
    && echo 'e3bd613b91b1c498ec2992276063342a85cd6edddd5521294e04f44bc055da9b  squid-7.7.tar.xz' | sha256sum -c - \
    && curl -fsSLO https://github.com/squid-cache/squid/releases/download/SQUID_7_7/squid-7.7.tar.xz.asc \
    && gpg --dearmor < /tmp/release-key.asc > /tmp/release-key.gpg \
    && gpgv --keyring /tmp/release-key.gpg squid-7.7.tar.xz.asc squid-7.7.tar.xz \
    && tar -xJf squid-7.7.tar.xz
WORKDIR /src/squid-7.7
# CONNECT is an opaque tunnel: no TLS library, interception, disk cache or helpers.
RUN ./configure --prefix=/usr --sysconfdir=/etc/squid --localstatedir=/var \
      --datadir=/usr/share/squid \
      --with-default-user=squid --disable-auth --disable-external-acl-helpers \
      --disable-url-rewrite-helpers --disable-storeid-rewrite-helpers \
      --disable-security-cert-validators --disable-security-cert-generators \
      --disable-log-daemon-helpers --disable-storeio --disable-disk-io \
      --disable-unlinkd --disable-icap-client --disable-wccp --disable-wccpv2 \
      --disable-snmp --disable-htcp --disable-eui --disable-zph-qos \
      --without-openssl --without-gnutls --without-nettle --without-cap \
    && make -j"$(nproc)" \
    && make DESTDIR=/out install \
    && strip /out/usr/sbin/squid

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache libstdc++ \
    && addgroup -S -g 10001 squid \
    && adduser -S -D -H -u 10001 -G squid squid
COPY --from=build /out/usr/sbin/squid /usr/sbin/squid
COPY --from=build /out/usr/share/squid /usr/share/squid
COPY --from=build /out/etc/squid/mime.conf /etc/squid/mime.conf
COPY squid.conf /etc/squid/squid.conf
USER 10001:10001
ENTRYPOINT ["/usr/sbin/squid", "-N", "-f", "/etc/squid/squid.conf"]

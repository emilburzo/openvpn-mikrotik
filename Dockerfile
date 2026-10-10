# OpenVPN server for MikroTik clients, on Alpine. Nothing else: no entrypoint script, no config, no keys.
#
# Pinned to OpenVPN 2.6 on purpose. RouterOS doesn't negotiate data ciphers and its client defaults
# to BF-CBC ("blowfish128"); 2.6 still serves that through OpenSSL's legacy provider. 2.7.6 and later
# ignore a second reset packet RouterOS v6 sends on every connect, so its handshake never finishes,
# and 2.8 drops BF-CBC. On an Alpine release without 2.6 this fails to build, instead of publishing
# an image MikroTiks can't connect to. See README.md.
FROM alpine:3.23
RUN apk add --no-cache 'openvpn~2.6'

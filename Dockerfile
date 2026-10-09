# OpenVPN server for MikroTik clients, on Alpine. Nothing else: no entrypoint script, no config, no keys.
#
# Pinned to OpenVPN 2.7 on purpose. RouterOS doesn't negotiate data ciphers and its client defaults
# to BF-CBC ("blowfish128"). 2.7 still serves that through OpenSSL's legacy provider; 2.8 drops BF-CBC.
# On an Alpine release without 2.7 this fails to build, instead of publishing an image MikroTiks
# can't connect to. See README.md.
FROM alpine:3.24
RUN apk add --no-cache 'openvpn~2.7'

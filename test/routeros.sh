#!/usr/bin/env bash
# Can the image still serve a MikroTik? Starts it as a server and connects an OpenVPN 2.4 client
# that behaves like RouterOS v6: TCP, no cipher negotiation, BF-CBC ("blowfish128", RouterOS's
# default) with SHA1, TLS 1.2. The client gets a net30 address from client-config-dir, and the
# server pings it through the tunnel.
#
# Usage: test/routeros.sh IMAGE
# Needs bash, openssl, and a docker that may run NET_ADMIN containers with /dev/net/tun.
set -euo pipefail

image=${1:?usage: $0 IMAGE}
client_image=alpine:3.12 # OpenVPN 2.4.12: the last line with --ncp-disable, so it can't negotiate
name=routeros-test-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name-server" "$name-client" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  echo "--- server log"; docker logs "$name-server" 2>&1 | tail -n 40
  echo "--- client log"; docker logs "$name-client" 2>&1 | tail -n 40
  exit 1
}

echo "Testing $(docker run --rm "$image" sh -c 'openvpn --version | head -1')"

# Throwaway PKI, valid for a day.
cd "$work"
mkdir -p server/ccd client
ext() { printf '%s\n' "$@" > ext.cnf; }
openssl req -new -newkey rsa:2048 -nodes -subj /CN=test-ca -keyout ca.key -out ca.csr 2>/dev/null
ext basicConstraints=critical,CA:TRUE keyUsage=critical,keyCertSign,cRLSign
openssl x509 -req -in ca.csr -signkey ca.key -days 1 -extfile ext.cnf -out ca.crt 2>/dev/null
issue() { # issue CN EXTENDED_KEY_USAGE
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$1" -keyout "$1.key" -out "$1.csr" 2>/dev/null
  ext basicConstraints=CA:FALSE keyUsage=critical,digitalSignature,keyEncipherment "extendedKeyUsage=$2"
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile ext.cnf -out "$1.crt" 2>/dev/null
}
issue server serverAuth
issue routeros clientAuth
cp ca.crt server.crt server.key server/
cp ca.crt routeros.crt routeros.key client/

# The server, with the settings a RouterOS client needs (README.md).
cat > server/openvpn.conf <<'EOF'
server 10.99.0.0 255.255.255.0
topology net30
proto tcp
port 1194
dev tun0
ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh none
client-config-dir /etc/openvpn/ccd
keepalive 10 60
persist-tun
user nobody
group nogroup
providers legacy default
data-ciphers AES-256-GCM:AES-128-GCM:BF-CBC
data-ciphers-fallback BF-CBC
disable-dco
verb 3
EOF
echo 'ifconfig-push 10.99.0.10 10.99.0.9' > server/ccd/routeros

# The client, behaving like RouterOS v6.
cat > client/client.conf <<'EOF'
client
dev tun
proto tcp-client
remote server 1194
nobind
remote-cert-tls server
cipher BF-CBC
ncp-disable
auth SHA1
tls-version-max 1.2
tls-cipher ECDHE-RSA-AES256-GCM-SHA384
ca /config/ca.crt
cert /config/routeros.crt
key /config/routeros.key
verb 3
EOF

# OpenVPN reads ccd/ again on every connect, after it has dropped to nobody.
chmod 755 server server/ccd client
chmod 644 server/ccd/routeros

docker network create "$name" >/dev/null
docker run -d --name "$name-server" --network "$name" --network-alias server \
  --cap-add NET_ADMIN --device /dev/net/tun -v "$work/server:/etc/openvpn:ro" \
  "$image" openvpn --config /etc/openvpn/openvpn.conf >/dev/null
# Not /etc/openvpn: the client installs openvpn at start, and the package writes there.
docker run -d --name "$name-client" --network "$name" \
  --cap-add NET_ADMIN --device /dev/net/tun -v "$work/client:/config:ro" \
  "$client_image" sh -c 'apk add -q --no-cache openvpn && exec openvpn --config /config/client.conf' >/dev/null

# Logs go into variables first: grep -q on a pipe can trip pipefail with SIGPIPE.
connected() { grep -q 'Initialization Sequence Completed' <<<"$(docker logs "$name-client" 2>&1)"; }
running() { ! grep -q false <<<"$(docker inspect -f '{{.State.Running}}' "$name-server" "$name-client")"; }
for _ in $(seq 90); do
  connected && break
  running || break
  sleep 1
done

connected || fail "the client didn't connect"
server_log=$(docker logs "$name-server" 2>&1)
grep -q 'Control Channel: TLSv1.2' <<<"$server_log" || fail "the control channel isn't TLS 1.2"
grep -q "Data Channel: cipher 'BF-CBC', auth 'SHA1'" <<<"$server_log" || fail "the data channel isn't BF-CBC with SHA1"
grep -q 'MULTI: Learn: 10.99.0.10 -> routeros' <<<"$server_log" || fail "the client didn't get its client-config-dir address"
docker exec "$name-server" ping -c 3 -W 2 10.99.0.10 >/dev/null || fail "no traffic through the tunnel"
echo "OK: a RouterOS-like client (TCP, no cipher negotiation, BF-CBC/SHA1, TLS 1.2, net30 address from ccd) connects and passes traffic"

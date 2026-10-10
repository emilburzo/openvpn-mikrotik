#!/usr/bin/env bash
# Can the image still serve a MikroTik? Starts it as a server and connects an OpenVPN 2.4 client
# that behaves like RouterOS v6: TCP, no cipher negotiation, BF-CBC ("blowfish128", RouterOS's
# default) with SHA1, TLS 1.2. The client gets a net30 address from client-config-dir, and the
# server pings it through the tunnel. Then a raw client sends RouterOS's second reset packet,
# which the server has to acknowledge.
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

# RouterOS v6 follows its first hard reset with a second one, packet id 1. OpenVPN 2.7.6 and later
# ignore that without an ACK (upstream commit d1e67f419f), and a real RouterOS then never gets past
# the reset: it gives up after 30 s and redials, over and over. The 2.4 client above doesn't send
# it, so a raw client does here.
cat > client/second-reset.py <<'EOF'
# A RouterOS v6 connect, up to its second reset. No tls-auth, so control packets are plain.
import os, socket, struct, sys, time

HARD_RESET_CLIENT_V2, HARD_RESET_SERVER_V2, ACK_V1 = 7, 8, 5

def send(s, session, packet_id, acks=(), peer=b""):
    # opcode + key id, session id, ack array (with the peer's session id), packet id
    body = bytes([HARD_RESET_CLIENT_V2 << 3]) + session + bytes([len(acks)])
    body += b"".join(struct.pack(">I", a) for a in acks) + (peer if acks else b"")
    body += struct.pack(">I", packet_id)
    s.sendall(struct.pack(">H", len(body)) + body)

def read(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise EOFError("the server closed the connection")
        data += chunk
    return data

def receive(s):
    (length,) = struct.unpack(">H", read(s, 2))
    p = read(s, length)
    op, session, count = p[0] >> 3, p[1:9], p[9]
    acks = list(struct.unpack(">%dI" % count, p[10:10 + 4 * count]))
    packet_id = None
    if op != ACK_V1:
        at = 10 + 4 * count + (8 if count else 0)
        (packet_id,) = struct.unpack(">I", p[at:at + 4])
    return op, session, acks, packet_id

try:
    s = socket.create_connection((sys.argv[1], 1194), timeout=5)
    me = os.urandom(8)
    send(s, me, 0)
    while True:
        op, server, acks, packet_id = receive(s)
        if op == HARD_RESET_SERVER_V2:
            break
    send(s, me, 1, acks=[packet_id], peer=server)
    deadline = time.time() + 5
    while time.time() < deadline:
        if 1 in receive(s)[2]:
            print("the server acknowledged the second reset")
            sys.exit(0)
except (OSError, EOFError) as e:
    print("error: %s" % e)
print("the server didn't acknowledge the second reset")
sys.exit(1)
EOF
reset=$(docker run --rm --network "$name" -v "$work/client:/config:ro" "$client_image" \
  sh -c 'apk add -q --no-cache python3 && exec python3 /config/second-reset.py server' 2>&1) ||
  fail "RouterOS's second reset: $reset"
echo "OK: a RouterOS-like client (TCP, no cipher negotiation, BF-CBC/SHA1, TLS 1.2, net30 address from ccd) connects and passes traffic, and its second reset is acknowledged"

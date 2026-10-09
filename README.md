# openvpn-mikrotik

An OpenVPN server image for MikroTik clients: OpenVPN 2.7 on Alpine Linux, for `linux/amd64` and `linux/arm64`, deliberately kept able to serve RouterOS's old OpenVPN client. Nothing else: no entrypoint script, no config, no keys. You mount your config and run `openvpn` yourself.

```sh
docker pull ghcr.io/emilburzo/openvpn-mikrotik:2.7
```

## Why it keeps the old stuff

RouterOS has its own OpenVPN implementation, and it's behind OpenVPN's:

- **It doesn't negotiate the data cipher.** [MikroTik's docs](https://help.mikrotik.com/docs/spaces/ROS/pages/2031655/OpenVPN): "Notable unsupported features: LZO compression (DEPRECATED) and NCP autonegotiation." The server has to fall back to whatever cipher the router is set to.
- **Its client defaults to `blowfish128`**, i.e. BF-CBC, with `sha1`.
- **RouterOS v6 is TCP-only**, since UDP came with v7. And v7 wants at least 64 MB of RAM, so older boards stay on v6 for good. The RB750G this image was made for has 32 MB.

OpenVPN keeps moving away from all that:
- OpenSSL 3 only has Blowfish in its legacy provider.
- A client that doesn't negotiate needs `data-ciphers-fallback`.
- 2.7 warns that OpenVPN 2.8 removes BF-CBC, and that net30 server pools go away in a future release.

So this image:

- **Stays on OpenVPN 2.7.** The Dockerfile asks for `openvpn~2.7`. On an Alpine release without 2.7 the build fails, instead of publishing something MikroTiks can't connect to.
- **Has OpenSSL's legacy provider**, which Alpine ships in `libcrypto3`.
- **Is tested on every build** against a client that behaves like RouterOS v6 ([`test/routeros.sh`](test/routeros.sh)):
  - TCP, with no cipher negotiation;
  - BF-CBC with SHA1, over TLS 1.2;
  - a net30 address from `client-config-dir`.

  Dependabot's Alpine updates have to pass it too.

If your routers can use AES instead (`aes256-cbc`), you don't need the legacy parts, but `data-ciphers-fallback` still has to match the router's cipher.

## Server settings for RouterOS clients

On top of your usual server config:

```
proto tcp                         # RouterOS v6 has no UDP
providers legacy default          # Blowfish lives in OpenSSL 3's legacy provider
data-ciphers AES-256-GCM:AES-128-GCM:BF-CBC
data-ciphers-fallback BF-CBC      # RouterOS doesn't negotiate: match its cipher
disable-dco                       # data channel offload only does AEAD ciphers
topology net30                    # only if your ccd/ lines are net30 style (ifconfig-push <ip> <peer>)
```

A working RouterOS connection looks like this in the server log:

```
Control Channel: TLSv1.2, cipher TLSv1.2 ECDHE-RSA-AES256-GCM-SHA384, ...
Data Channel: cipher 'BF-CBC', auth 'SHA1', peer-id: 0
```

## Tags

| Tag | Example | Moves on |
|---|---|---|
| `latest` | | every published build |
| `<minor>` | `2.7` | every published build of that minor version |
| `<version>` | `2.7.7` | every published build of that version, e.g. an OpenSSL fix |
| `<version>-<build>` | `2.7.7-12` | never |

A build is published on every push to `main`, on manual runs, and by the weekly rebuild when any installed Alpine package changed since the last published build.

## Usage

Docker:

```sh
docker run -d --name openvpn \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -p 1194:1194/tcp -v /srv/openvpn:/etc/openvpn:ro \
  ghcr.io/emilburzo/openvpn-mikrotik:2.7 \
  openvpn --config /etc/openvpn/openvpn.conf
```

Kubernetes has no `--device`, so the container creates the device node itself. Tested with only `NET_ADMIN` on k3s 1.36 (containerd 2.3), no `privileged`:

```yaml
containers:
  - name: openvpn
    image: ghcr.io/emilburzo/openvpn-mikrotik:2.7
    command:
      - sh
      - -c
      - mkdir -p /dev/net && { [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200; } && exec openvpn --config /etc/openvpn/openvpn.conf
    securityContext:
      capabilities:
        add: [NET_ADMIN]
```

With `user nobody` in the config, OpenVPN reads the `crl-verify` file and the `client-config-dir` files again on every connect, after it has dropped root. Make them world-readable, e.g. `mode: 0444` on those Secret items.

## Coming from kylemanna/openvpn

[kylemanna/openvpn](https://github.com/kylemanna/docker-openvpn) is amd64-only and stuck on OpenVPN 2.4 since 2020. What to carry over when moving one of its servers here:

- **Hidden flags.** kylemanna's `ovpn_run` adds `--client-config-dir` and `--crl-verify` on the command line, plus iptables MASQUERADE rules for the VPN subnets. None of that is in its `openvpn.conf`. Put the two options in the config, and add NAT yourself if you need it.
- **Topology.** 2.7 defaults to `topology subnet`, while kylemanna's configs are net30. If your `ccd/` files use `ifconfig-push <ip> <peer>`, add `topology net30`.
- **Ciphers.** `cipher` no longer picks the data cipher. Use the settings above.
- **Deprecations.** `persist-key` is ignored now (keys are always kept), which is harmless.

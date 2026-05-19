# CA Faker & CA Pusher

Create a self-signed CA and push trust to remote Ubuntu nodes for Qumulo cluster TLS.

## Requirements

- Cluster A: bash, openssl, ssh (root access)
- Cluster A: sshpass (only if using password-based SSH)
- Cluster B nodes: Ubuntu with a sudo-capable SSH user

## Quick Start

### 1. Generate CA + server certificate

```bash
sudo ./CA_Faker.sh \
  --cn myserver.lab.example.com \
  --san "dns:myserver.lab.example.com,dns:*.myserver.lab.example.com,ip:10.10.10.10" \
  --out-dir /root/qumulo-tls
```

### 2. Create a clients file

One hostname or IP per line. Blank lines and `#` comments are ignored.

```
node1.lab.example.com
node2.lab.example.com
node3.lab.example.com
```

### 3. Push CA to remote nodes

Push the CA cert to each host and its `qcore` nspawn container, then verify
that TLS actually works end-to-end:

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls \
  --user admin \
  --auth key \
  --container qcore \
  --verify-tls myserver.lab.example.com:443
```

If your nodes do not run nspawn containers, omit `--container`.
If you don't have a TLS endpoint to test against yet, omit `--verify-tls`.

### 4. Apply TLS to Qumulo

```bash
qq ssl_modify_certificate \
  -c /root/qumulo-tls/certbundle.pem \
  -k /root/qumulo-tls/private.key.insecure
```

## CA_Faker.sh Options

| Flag | Description |
|------|-------------|
| `--cn <fqdn>` | **(required)** Server Common Name |
| `--san <list>` | SAN list, e.g. `"dns:a.com,ip:10.0.0.1"` (default: `dns:<cn>`) |
| `--out-dir <path>` | Output directory (default: `/root/qumulo-tls`) |
| `--server-days <n>` | Server cert validity in days (default: 825) |
| `--ca-days <n>` | CA cert validity in days (default: 3650) |
| `--force-reissue` | Regenerate server key/cert even if already present |

## CA_Pusher.sh Options

| Flag | Description |
|------|-------------|
| `--clients <file>` | **(required)** File with target hostnames/IPs |
| `--ca <dir>` | **(required)** Output directory from CA_Faker.sh |
| `--user <name>` | SSH username (prompts if omitted) |
| `--auth key\|password` | SSH auth method (prompts if omitted; `password` requires sshpass) |
| `--key <path>` | SSH private key path |
| `--port <n>` | SSH port (default: 22) |
| `--container <name>` | Also install cert into a systemd-nspawn container on each host |
| `--verify-tls <host:port>` | End-to-end TLS check from host and container after install |
| `--no-verify` | Skip post-install trust-store verification |
| `--timeout <sec>` | SSH connect timeout (default: 8) |

## Output Files

```
<out-dir>/
  private.key.insecure   # Server private key (unencrypted)
  certbundle.pem         # Leaf + CA bundle (Qumulo order)
  ca/ca.crt.pem          # Root CA cert (distribute to clients)
  ca/ca.key.pem          # Root CA key (protect this)
  issued/server.crt.pem  # Server leaf cert
  csr/server.csr.pem     # Certificate signing request
```

## Manual Testing

The `--verify-tls` flag handles end-to-end verification automatically. The
commands below are useful for debugging if something goes wrong.

Verify the certificate chain locally:

```bash
openssl verify -CAfile /root/qumulo-tls/ca/ca.crt.pem \
  /root/qumulo-tls/issued/server.crt.pem
# Expected: server.crt.pem: OK
```

Test a TLS connection from a Cluster B node:

```bash
echo | openssl s_client -connect <cluster-a-host>:443 -brief
# Look for: Verification: OK
```

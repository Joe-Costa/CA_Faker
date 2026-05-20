# CA Faker & CA Pusher

Generate a self-signed CA and server certificate, push the CA trust to remote
Ubuntu nodes (and their nspawn containers), and apply TLS to a Qumulo cluster.

## How It Works

Both scripts run from any admin machine (your laptop, a jump box, etc.) —
nothing needs to run on a Qumulo node.

1. **CA_Faker.sh** generates a root CA and server certificate locally.
2. **CA_Pusher.sh** SSHes into each client node and installs the CA cert into
   the host's trust store (and optionally into a systemd-nspawn container).
3. You apply the server certificate to the Qumulo cluster via `qq` CLI.

## Requirements

Admin machine (where you run the scripts):
- bash, openssl, ssh
- sshpass (only if using password-based SSH auth)

Remote nodes (targets of CA_Pusher.sh):
- **Ubuntu target machine** with a sudo-capable SSH user
- This process currently does nto support any other Linux distros or OS'es as targets
- Optional: systemd-nspawn container (e.g. `qcore`)

## Quick Start

### 1. Generate CA + server certificate (run on your admin machine)

```bash
./CA_Faker.sh \
  --cn myserver.lab.example.com \
  --out-dir ./qumulo-tls
```

This creates the output files locally in `--out-dir`. No root required, no
remote hosts contacted.

### 2. Create a clients file

List the remote nodes that need to trust your CA — one hostname or IP per line.
Blank lines and `#` comments are ignored.

```
node1.lab.example.com
node2.lab.example.com
node3.lab.example.com
```

### 3. Push CA to remote nodes (run on your admin machine)

Push the CA cert to each node and its `qcore` nspawn container, then verify
that TLS works end-to-end:

```bash
./CA_Pusher.sh \
  --clients clients.txt \
  --ca ./qumulo-tls \
  --ssh-user admin \
  --auth key \
  --container qcore \
  --verify-tls myserver.lab.example.com:443
```

If your nodes do not run nspawn containers, omit `--container`.
If you don't have a TLS endpoint to test against yet, omit `--verify-tls`.

### 4. Apply TLS to Qumulo

From your admin machine (where CA_Faker.sh was run, assumign the `qq` CLI is available - This is the easiest method):

```bash
qq --host your.qumulo.cluster.com ssl_modify_certificate \
  -c ./qumulo-tls/certbundle.pem \
  -k ./qumulo-tls/private.key.insecure
```

Or from inside a `qcore` container. CA_Pusher installs the CA cert at
`/usr/local/share/ca-certificates/company-lab-root-ca.crt`, but the
certbundle and private key must be copied separately:

```bash
# From your admin machine, copy the files into the container via the host:
scp ./qumulo-tls/certbundle.pem ./qumulo-tls/private.key.insecure \
  admin@node1:/tmp/

# On the host, copy into the container:
sudo machinectl copy-to qcore /tmp/certbundle.pem /tmp/certbundle.pem
sudo machinectl copy-to qcore /tmp/private.key.insecure /tmp/private.key.insecure

# Inside the container:
qq ssl_modify_certificate \
  -c /tmp/certbundle.pem \
  -k /tmp/private.key.insecure
```

## CA_Faker.sh Options

| Flag | Description |
|------|-------------|
| `--cn <fqdn>` | **(required)** Server Common Name |
| `--san <list>` | SAN list, e.g. `"dns:a.com,ip:10.0.0.1"` (default: `dns:<cn>`) |
| `--out-dir <path>` | Output directory (default: `./qumulo-tls`) |
| `--server-days <n>` | Server cert validity in days (default: 825) |
| `--ca-days <n>` | CA cert validity in days (default: 3650) |
| `--force-reissue` | Regenerate server key/cert even if already present |

## CA_Pusher.sh Options

| Flag | Description |
|------|-------------|
| `--clients <file>` | **(required)** File with target hostnames/IPs |
| `--ca <dir>` | **(required)** Output directory from CA_Faker.sh |
| `--ssh-user <name>` | SSH username (prompts if omitted) |
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
openssl verify -CAfile ./qumulo-tls/ca/ca.crt.pem \
  ./qumulo-tls/issued/server.crt.pem
# Expected: server.crt.pem: OK
```

Test a TLS connection from a Cluster B node:

```bash
echo | openssl s_client -connect <cluster-a-host>:443 -brief
# Look for: Verification: OK
```

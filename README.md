# CA Faker & CA Pusher

Lab tools for creating a self-signed Certificate Authority and distributing trust to remote Ubuntu nodes. Designed for Qumulo cluster TLS setup where Cluster A serves TLS and Cluster B nodes need to trust it.

## Overview

| Script | Purpose | Runs on |
|---|---|---|
| `CA_Faker.sh` | Creates a root CA + signed server certificate with SANs | Cluster A (the TLS server) |
| `CA_Pusher.sh` | Pushes the CA cert to remote nodes and installs it into the Ubuntu trust store | Cluster A (connects to Cluster B nodes via SSH) |

## Requirements

**Cluster A** (where you run both scripts):
- bash, openssl, sed
- ssh, scp (for CA_Pusher.sh)
- sshpass (only if using password-based SSH auth)
- Root access

**Cluster B nodes** (remote targets for CA_Pusher.sh):
- Ubuntu (uses `update-ca-certificates`)
- SSH access with a user that has sudo privileges

## Quick Start

### 1. Generate the CA and server certificate

```bash
sudo ./CA_Faker.sh \
  --cn myserver.lab.example.com \
  --out-dir /root/qumulo-tls
```

This creates:

```
/root/qumulo-tls/
  private.key.insecure        # Server private key (unencrypted PEM)
  certbundle.pem              # Leaf cert + root CA (Qumulo bundle order)
  ca/
    ca.crt.pem                # Root CA cert (distribute this to clients)
    ca.key.pem                # Root CA private key (protect this!)
  issued/
    server.crt.pem            # Server leaf certificate
  csr/
    server.csr.pem            # Certificate signing request
```

### 2. Push the CA to remote nodes

Create a clients file with one hostname/IP per line:

```bash
cat > clients.txt <<'EOF'
node1.lab.example.com
node2.lab.example.com
node3.lab.example.com
# node4.lab.example.com   (commented out, will be skipped)
EOF
```

Push the CA cert and install it in the Ubuntu trust store on each node:

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls
```

The script will prompt for SSH username, auth method, and the remote sudo password.

### 3. Apply the TLS cert to Qumulo (manual step)

```bash
qq ssl_modify_certificate \
  -c /root/qumulo-tls/certbundle.pem \
  -k /root/qumulo-tls/private.key.insecure
```

## CA_Faker.sh Usage

```
Usage: CA_Faker.sh --cn <fqdn> [options]

Required:
  --cn <fqdn>                 Server certificate Common Name

Optional:
  --san <list>                SAN list (default: "dns:<cn>")
                              Format: dns:name,ip:addr
  --out-dir <path>            Output directory (default: /root/qumulo-tls)
  --server-days <days>        Server cert validity (default: 825)
  --ca-days <days>            CA cert validity (default: 3650)
  --force-reissue             Regenerate server key/cert even if present
  --help                      Show help
```

### Examples

Minimal (CN only, SAN defaults to the CN):

```bash
sudo ./CA_Faker.sh --cn datacore.company.com
```

With wildcard SAN and IP:

```bash
sudo ./CA_Faker.sh \
  --cn datacore.company.com \
  --san "dns:datacore.company.com,dns:*.datacore.company.com,ip:10.10.10.10" \
  --out-dir /root/qumulo-tls
```

Re-issue the server cert (keeps existing CA):

```bash
sudo ./CA_Faker.sh \
  --cn datacore.company.com \
  --force-reissue \
  --out-dir /root/qumulo-tls
```

## CA_Pusher.sh Usage

```
Usage: CA_Pusher.sh --clients <file> --ca <dir> [options]

Required:
  --clients <file>        File with one client IP/hostname/FQDN per line
  --ca <dir>              Output directory from CA_Faker.sh

Optional:
  --user <name>           SSH username (prompts if omitted)
  --port <n>              SSH port (default: 22)
  --auth key              Use SSH key auth
  --auth password         Use password SSH auth (requires sshpass)
  --key <path>            SSH private key path (for --auth key)
  --no-verify             Skip verification step
  --timeout <sec>         SSH connect timeout (default: 8)
  --help                  Show help
```

### Examples

Interactive (prompts for username, auth method, and sudo password):

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls
```

Non-interactive with SSH key auth:

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls \
  --user admin \
  --auth key \
  --key ~/.ssh/id_rsa
```

Non-interactive with password auth (requires `sshpass`):

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls \
  --user admin \
  --auth password
```

Custom SSH port, skip verification:

```bash
sudo ./CA_Pusher.sh \
  --clients clients.txt \
  --ca /root/qumulo-tls \
  --user admin \
  --auth key \
  --port 2222 \
  --no-verify
```

## Testing

### Verify the generated certificates

Inspect the CA:

```bash
openssl x509 -in /root/qumulo-tls/ca/ca.crt.pem -noout -subject -issuer -dates
```

Inspect the server cert and its SANs:

```bash
openssl x509 -in /root/qumulo-tls/issued/server.crt.pem -noout -subject -issuer -dates
openssl x509 -in /root/qumulo-tls/issued/server.crt.pem -noout -ext subjectAltName
```

Verify the chain (server cert signed by the CA):

```bash
openssl verify -CAfile /root/qumulo-tls/ca/ca.crt.pem \
  /root/qumulo-tls/issued/server.crt.pem
```

Expected output: `server.crt.pem: OK`

### Test TLS with openssl s_server / s_client

Start a test TLS server on Cluster A:

```bash
openssl s_server \
  -cert /root/qumulo-tls/certbundle.pem \
  -key /root/qumulo-tls/private.key.insecure \
  -accept 4433
```

Connect from a Cluster B node that has the CA installed (after running CA_Pusher.sh):

```bash
# Uses the system trust store (installed by CA_Pusher.sh)
openssl s_client -connect <cluster-a-host>:4433

# Or explicitly specify the CA cert
openssl s_client -connect <cluster-a-host>:4433 \
  -CAfile /path/to/ca.crt.pem
```

A successful connection shows `Verify return code: 0 (ok)` at the bottom of the output.

A failed connection shows `Verify return code: 20 (unable to get local issuer certificate)`, which means the CA is not trusted on that client yet.

### Test with curl

From a Cluster B node after CA_Pusher.sh has run:

```bash
# Should succeed (system trust store has the CA)
curl https://<cluster-a-host>:4433

# If the CA hasn't been pushed yet, force it for testing
curl --cacert /path/to/ca.crt.pem https://<cluster-a-host>:4433
```

### Verify trust store installation on a remote node

SSH into a Cluster B node and check:

```bash
# Cert should be present
ls -la /usr/local/share/ca-certificates/company-lab-root-ca.crt

# Symlink should exist in the system store
ls /etc/ssl/certs/ | grep company-lab-root-ca

# Full verification against the system trust store
openssl verify /usr/local/share/ca-certificates/company-lab-root-ca.crt
```

## Output Structure

```
<out-dir>/
  private.key.insecure           # Server private key (unencrypted)
  certbundle.pem                 # leaf cert + CA cert (Qumulo bundle order)
  ca/
    ca.crt.pem                   # Root CA certificate (distribute to clients)
    ca.key.pem                   # Root CA private key (keep secret)
  issued/
    server.crt.pem               # Server leaf certificate only
  csr/
    server.csr.pem               # Certificate signing request
  tmp/
    server_ext.cnf               # OpenSSL extensions file (auto-generated)
```

## Security Notes

- `ca.key.pem` is the root CA private key. Anyone with this file can issue trusted certificates. Protect it accordingly.
- `private.key.insecure` is unencrypted by design (Qumulo requires it). Restrict file permissions.
- CA_Pusher.sh holds the sudo password only in memory and passes it via stdin to `sudo -S`. It never appears on any command line or in `/proc`.
- The root install script is base64-encoded for safe transport. It is decoded to a temp file on the remote host, executed, then deleted.
- Both scripts set `umask 077` or explicit permissions on sensitive files.

#!/usr/bin/env bash
# push_ca_trust_to_clusterB_ubuntu.sh
#
# Run this on Cluster A.
#
# Given:
#   --clients <file>   : list of Cluster B client IPs/hosts/FQDNs (one per line)
#   --ca <dir>         : the *directory* created by your Cluster A CA creation tool
#                        (i.e. the same --out-dir you used there, e.g. /root/qumulo-tls)
#
# This script:
#   1) pulls the CA cert from: <dir>/ca/ca.crt.pem
#   2) prompts for SSH username
#   3) prompts for SSH auth method (key or password)
#   4) prompts for the remote sudo password (user is NOT passwordless sudoer)
#   5) copies the CA cert to each client
#   6) installs it into Ubuntu trust store (/usr/local/share/ca-certificates)
#   7) runs update-ca-certificates
#
# Requirements (on Cluster A):
#   - bash, ssh, scp, openssl
#   - OPTIONAL: sshpass (only if using password-based SSH)
#       sudo apt-get update && sudo apt-get install -y sshpass
#
# Usage:
#   sudo ./push_ca_trust_to_clusterB_ubuntu.sh \
#     --clients ./clusterB_hosts.txt \
#     --ca /root/qumulo-tls
#
# Clients file format:
#   One host/IP/FQDN per line. Blank lines and lines starting with # are ignored.
#
# Security notes:
# - The sudo password is read from stdin (hidden) and held only in memory.
# - We do NOT place the password on any command line; it is passed via stdin.
# - The root script is base64-encoded and decoded on the remote side to avoid
#   quoting and stdin conflicts with the sudo password delivery.

set -euo pipefail

CLIENTS_FILE=""
CA_DIR=""             # directory created by CA creation tool (out-dir)
CA_CERT=""            # resolved to CA_DIR/ca/ca.crt.pem
SSH_USER=""
SSH_PORT="22"
AUTH_MODE=""          # "key" or "password"
SSH_KEY_PATH=""       # used if AUTH_MODE=key (optional)
VERIFY=1
CONNECT_TIMEOUT=8

# In-memory secrets
SSHPASS=""            # only if AUTH_MODE=password (sshpass)
SUDO_PASS=""          # always required (remote sudo password)

usage() {
  cat <<EOF
Usage: $0 --clients <file> --ca <ca-tool-out-dir> [options]

Required:
  --clients <file>        File with one client IP/hostname/FQDN per line
  --ca <dir>              Directory created by CA creation tool (e.g. /root/qumulo-tls)
                          CA cert is expected at: <dir>/ca/ca.crt.pem

Optional:
  --user <name>           SSH username (if omitted, will prompt)
  --port <n>              SSH port (default: $SSH_PORT)
  --auth key              Use SSH key auth
  --auth password         Use password SSH auth (requires sshpass)
  --key <path>            SSH private key path (for --auth key)
  --no-verify             Skip verification step
  --timeout <sec>         SSH connect timeout (default: $CONNECT_TIMEOUT)
  --help                  Show help

EOF
}

err()  { echo "ERROR: $*" >&2; }
info() { echo "INFO:  $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

cleanup() {
  SSHPASS=""
  SUDO_PASS=""
  unset SSHPASS SUDO_PASS
}
trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clients) CLIENTS_FILE="${2:-}"; shift 2 ;;
      --ca) CA_DIR="${2:-}"; shift 2 ;;
      --user) SSH_USER="${2:-}"; shift 2 ;;
      --port) SSH_PORT="${2:-}"; shift 2 ;;
      --auth) AUTH_MODE="${2:-}"; shift 2 ;;
      --key) SSH_KEY_PATH="${2:-}"; shift 2 ;;
      --no-verify) VERIFY=0; shift 1 ;;
      --timeout) CONNECT_TIMEOUT="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -z "$CLIENTS_FILE" || ! -f "$CLIENTS_FILE" ]]; then
    err "--clients file is required and must exist"; exit 1
  fi

  if [[ -z "$CA_DIR" || ! -d "$CA_DIR" ]]; then
    err "--ca must point to the CA tool output directory and must exist"; exit 1
  fi

  CA_CERT="${CA_DIR%/}/ca/ca.crt.pem"
  if [[ ! -f "$CA_CERT" ]]; then
    err "CA cert not found at expected path: $CA_CERT"
    err "Ensure --ca points to the same --out-dir used by the CA creation tool."
    exit 1
  fi

  if ! openssl x509 -in "$CA_CERT" -noout >/dev/null 2>&1; then
    err "CA file does not look like a valid PEM X.509 cert: $CA_CERT"; exit 1
  fi

  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
    err "--port must be a valid TCP port"; exit 1
  fi
  if ! [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$CONNECT_TIMEOUT" -lt 1 ]]; then
    err "--timeout must be a positive integer"; exit 1
  fi
  if [[ -n "$AUTH_MODE" && "$AUTH_MODE" != "key" && "$AUTH_MODE" != "password" ]]; then
    err "--auth must be 'key' or 'password'"; exit 1
  fi
  if [[ -n "$SSH_KEY_PATH" && ! -f "$SSH_KEY_PATH" ]]; then
    err "--key path not found: $SSH_KEY_PATH"; exit 1
  fi
}

prompt_creds() {
  if [[ -z "$SSH_USER" ]]; then
    read -r -e -p "SSH username for Cluster B nodes: " SSH_USER
  fi
  if [[ -z "$SSH_USER" ]]; then
    err "SSH username cannot be empty"; exit 1
  fi

  if [[ -z "$AUTH_MODE" ]]; then
    echo "Choose SSH auth method:"
    echo "  1) key (recommended)"
    echo "  2) password (requires sshpass)"
    read -r -e -p "Selection [1/2]: " sel
    case "$sel" in
      2) AUTH_MODE="password" ;;
      *) AUTH_MODE="key" ;;
    esac
  fi

  case "$AUTH_MODE" in
    key)
      if [[ -z "$SSH_KEY_PATH" ]]; then
        read -r -e -p "SSH key path (leave blank to use ssh-agent/default config): " SSH_KEY_PATH || true
      fi
      ;;
    password)
      need_cmd sshpass
      read -r -e -s -p "SSH password for ${SSH_USER}: " SSHPASS
      echo
      if [[ -z "$SSHPASS" ]]; then
        err "Password auth selected but SSH password was empty"; exit 1
      fi
      export SSHPASS
      ;;
  esac

  # Always required because user is NOT passwordless sudoer
  read -r -e -s -p "Remote sudo password for ${SSH_USER}: " SUDO_PASS
  echo
  if [[ -z "$SUDO_PASS" ]]; then
    err "Remote sudo password cannot be empty"; exit 1
  fi
}

ssh_opts_base() {
  echo "-p ${SSH_PORT} -o ConnectTimeout=${CONNECT_TIMEOUT} -o StrictHostKeyChecking=accept-new"
}

# Run a remote command as the SSH user (no sudo). Allocates TTY.
run_ssh_user() {
  local host="$1"; shift
  local opts; opts="$(ssh_opts_base)"

  if [[ "$AUTH_MODE" == "password" ]]; then
    sshpass -e ssh -tt $opts -o BatchMode=no "${SSH_USER}@${host}" "$@"
  else
    if [[ -n "$SSH_KEY_PATH" ]]; then
      ssh -tt $opts -o BatchMode=yes -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "$@"
    else
      ssh -tt $opts -o BatchMode=yes "${SSH_USER}@${host}" "$@"
    fi
  fi
}

# Run a remote command without TTY allocation (for non-interactive scripts).
# Stdin is forwarded to the remote command, so callers can pipe data in.
run_ssh_no_tty() {
  local host="$1"; shift
  local opts; opts="$(ssh_opts_base)"

  if [[ "$AUTH_MODE" == "password" ]]; then
    sshpass -e ssh -T $opts -o BatchMode=no "${SSH_USER}@${host}" "$@"
  else
    if [[ -n "$SSH_KEY_PATH" ]]; then
      ssh -T $opts -o BatchMode=yes -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "$@"
    else
      ssh -T $opts -o BatchMode=yes "${SSH_USER}@${host}" "$@"
    fi
  fi
}

# Copy a file to remote host
run_scp() {
  local src="$1"
  local host="$2"
  local dst="$3"

  if [[ "$AUTH_MODE" == "password" ]]; then
    sshpass -e scp -P "${SSH_PORT}" -o ConnectTimeout="${CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new -o BatchMode=no \
      "$src" "${SSH_USER}@${host}:$dst"
  else
    if [[ -n "$SSH_KEY_PATH" ]]; then
      scp -P "${SSH_PORT}" -o ConnectTimeout="${CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -i "$SSH_KEY_PATH" "$src" "${SSH_USER}@${host}:$dst"
    else
      scp -P "${SSH_PORT}" -o ConnectTimeout="${CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        "$src" "${SSH_USER}@${host}:$dst"
    fi
  fi
}

# Run a root script on remote host via sudo -S.
# The script is base64-encoded and passed as a command argument to avoid
# stdin conflicts.  The sudo password is piped via stdin to the remote
# command, which reads it and feeds it to sudo -S.
run_remote_sudo_script() {
  local host="$1"
  local root_script="$2"

  # Base64-encode the script so it can be safely embedded in a command string
  local b64_script
  b64_script="$(printf '%s' "$root_script" | base64 | tr -d '\n')"

  # Remote command sequence:
  #   1. read the sudo password from stdin (first and only line)
  #   2. decode the base64 payload into a temp script
  #   3. run the temp script under sudo -S (password piped in)
  #   4. clean up and propagate the exit code
  local remote_cmd
  remote_cmd="read -r _PW \
&& echo '${b64_script}' | base64 -d > /tmp/_ca_push_script.sh \
&& chmod 600 /tmp/_ca_push_script.sh \
&& printf '%s\\n' \"\$_PW\" | sudo -S bash /tmp/_ca_push_script.sh; \
_rc=\$?; rm -f /tmp/_ca_push_script.sh; exit \$_rc"

  # Pipe the sudo password as stdin; use no-TTY ssh to prevent interactive shell
  printf '%s\n' "$SUDO_PASS" | run_ssh_no_tty "$host" "$remote_cmd"
}

install_on_node() {
  local host="$1"

  info "[$host] installing CA into Ubuntu trust store (sudo required)"

  # Embed the CA cert directly in the payload — avoids SCP and the
  # temp-file permission issue (previous runs leave root-owned files in /tmp).
  local b64_cert
  b64_cert="$(base64 < "$CA_CERT" | tr -d '\n')"

  local root_script
  root_script="$(cat <<'RSCRIPT'
set -euo pipefail
DST="/usr/local/share/ca-certificates/company-lab-root-ca.crt"

echo '__B64_CERT__' | base64 -d > "$DST"
chmod 0644 "$DST"

openssl x509 -in "$DST" -noout >/dev/null 2>&1 || { echo "Bad CA cert at $DST" >&2; exit 1; }

update-ca-certificates >/dev/null

echo "Installed: $DST"
openssl x509 -in "$DST" -noout -subject -fingerprint -sha256

# Clean up stale temp file from older script versions
rm -f /tmp/company-lab-root-ca.crt
RSCRIPT
)"
  root_script="${root_script/__B64_CERT__/$b64_cert}"

  run_remote_sudo_script "$host" "$root_script"

  if [[ "$VERIFY" -eq 1 ]]; then
    info "[$host] verify: best-effort check in /etc/ssl/certs"
    run_ssh_user "$host" "ls -1 /etc/ssl/certs | grep -i 'company-lab-root-ca' || true"
  fi

  info "[$host] done"
}

main() {
  need_cmd ssh
  need_cmd scp
  need_cmd openssl

  parse_args "$@"
  prompt_creds

  info "CA tool output dir: $CA_DIR"
  info "Resolved CA cert:   $CA_CERT"
  info "Clients file:       $CLIENTS_FILE"
  info "SSH user:           $SSH_USER"
  info "SSH port:           $SSH_PORT"
  info "Auth mode:          $AUTH_MODE"
  [[ "$AUTH_MODE" == "key" && -n "$SSH_KEY_PATH" ]] && info "SSH key:            $SSH_KEY_PATH"
  [[ "$VERIFY" -eq 1 ]] && info "Verification:       enabled" || info "Verification:       disabled"

  local total=0 ok=0 fail=0
  local failures=()

  while IFS= read -r host <&3; do
    host="$(echo "$host" | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$host" ]] && continue

    total=$((total+1))
    echo "=============================="
    echo "Target: $host"
    echo "=============================="

    if install_on_node "$host"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
      failures+=("$host")
      err "[$host] failed (continuing)"
    fi
    echo
  done 3< "$CLIENTS_FILE"

  echo "=============================="
  echo "Summary"
  echo "=============================="
  echo "Total: $total"
  echo "OK:    $ok"
  echo "Fail:  $fail"
  if [[ "$fail" -gt 0 ]]; then
    echo
    echo "Failed nodes:"
    printf '  %s\n' "${failures[@]}"
    exit 2
  fi
}

main "$@"
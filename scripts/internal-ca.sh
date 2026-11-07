#!/usr/bin/env sh
# Generates the internal CA of one environment and the server certificate of csp-catalog-api (ADR-067). openssl only.
# usage: ./scripts/internal-ca.sh dev|qa|main
# Each environment has its own CA (csp-internal-ca, RSA 3072, 1 year), never shared. The certificate of Catalog (RSA 2048, 90 days)
# has the names catalog-api and localhost and is issued by that CA. Output, all in keys/tls/<environment>/ (git-ignored):
#   ca.key       private key of the CA: it stays here, no container mounts it, no repository holds it
#   ca.crt       public certificate of the CA: the file the callers trust (CATALOG_TLS_CA_HOST_FILE)
#   catalog.crt  chain PEM: the certificate of Catalog followed by the CA (CATALOG_TLS_CERTIFICATE_HOST_FILE)
#   catalog.key  private key of Catalog (CATALOG_TLS_PRIVATE_KEY_HOST_FILE)
# Run it again to renew: the CA is kept while it is valid for more than 30 days, and a new certificate of Catalog is issued
# (every 90 days, before it expires). The services re-read the files, so a renewed certificate needs no restart.
# TLS_OUT_DIR overrides the output folder; the env file is then left alone (used by scripts/test-internal-ca.sh).
set -eu
cd "$(dirname "$0")/.."
environment="${1:-}"
case "$environment" in dev|qa|main) ;; *) echo "usage: $0 dev|qa|main"; exit 1 ;; esac
out="${TLS_OUT_DIR:-keys/tls}/$environment"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The subject goes in a config file, not in -subj: Git Bash rewrites an argument that starts with a slash into a Windows path.
subject_config() { printf '[req]
prompt=no
distinguished_name=dn
[dn]
CN=%s
O=cinesync-platform
OU=%s
' "$1" "$environment"; }

# The CA is kept while it still has more than 30 days: renewing the leaf must not change what the callers trust.
if [ -f "$out/ca.key" ] && [ -f "$out/ca.crt" ] && openssl x509 -in "$out/ca.crt" -noout -checkend 2592000 >/dev/null; then
  echo "CA of $environment kept"
else
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$out/ca.key" 2>/dev/null
  printf '[v3]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > "$work/ca.ext"
  subject_config "csp-internal-ca" > "$work/ca.req"
  openssl req -new -config "$work/ca.req" -key "$out/ca.key" -out "$work/ca.csr"
  openssl x509 -req -in "$work/ca.csr" -signkey "$out/ca.key" -days 365 -sha256 -extfile "$work/ca.ext" -extensions v3 -out "$out/ca.crt" 2>/dev/null
  echo "CA of $environment created (valid 1 year)"
fi

printf '[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:catalog-api,DNS:localhost\nauthorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n' > "$work/catalog.ext"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/catalog.key" 2>/dev/null
subject_config "catalog-api" > "$work/catalog.req"
openssl req -new -config "$work/catalog.req" -key "$work/catalog.key" -out "$work/catalog.csr"
openssl x509 -req -in "$work/catalog.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -CAserial "$work/ca.srl" \
  -days 90 -sha256 -extfile "$work/catalog.ext" -extensions v3 -out "$work/catalog.crt" 2>/dev/null
cat "$work/catalog.crt" "$out/ca.crt" > "$out/catalog.crt"
cp "$work/catalog.key" "$out/catalog.key"
# The container user is not the owner of the file on a Linux host, so the key of Catalog is readable; the key of the CA is not.
chmod 600 "$out/ca.key"
chmod 644 "$out/ca.crt" "$out/catalog.crt" "$out/catalog.key"
echo "Certificate of Catalog issued for $environment (valid 90 days, renew before it expires): $out"

[ -z "${TLS_OUT_DIR:-}" ] || exit 0
# The paths compose mounts: absolute, and in the form Docker Desktop reads on Windows (pwd -W under Git Bash).
host_dir="$(cd "$out" && { pwd -W 2>/dev/null || pwd; })"
env_file="env/$environment.env"
[ -f "$env_file" ] || cp "env/$environment.env.example" "$env_file"
grep -v -e '^CATALOG_TLS_CERTIFICATE_HOST_FILE=' -e '^CATALOG_TLS_PRIVATE_KEY_HOST_FILE=' -e '^CATALOG_TLS_CA_HOST_FILE=' "$env_file" > "$env_file.tmp" || true
printf 'CATALOG_TLS_CERTIFICATE_HOST_FILE=%s/catalog.crt\n' "$host_dir" >> "$env_file.tmp"
printf 'CATALOG_TLS_PRIVATE_KEY_HOST_FILE=%s/catalog.key\n' "$host_dir" >> "$env_file.tmp"
printf 'CATALOG_TLS_CA_HOST_FILE=%s/ca.crt\n' "$host_dir" >> "$env_file.tmp"
mv "$env_file.tmp" "$env_file"
echo "$env_file updated with the three CATALOG_TLS_*_HOST_FILE paths"

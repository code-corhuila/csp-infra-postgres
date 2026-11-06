#!/usr/bin/env sh
# Checks scripts/internal-ca.sh (ADR-067) and the deployment files that state the TLS variables. Prints the totals; exits 1 on any failure.
# usage: ./scripts/test-internal-ca.sh
set -u
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
check() {  # description, command...
  description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   $description"; else fail=$((fail + 1)); echo "FAIL $description"; fi
}
refused() { ! "$@"; }
contains() { openssl x509 -in "$1" -noout -text | grep -q -- "$2"; }
day=86400

export TLS_OUT_DIR="$tmp"
for e in dev qa main; do ./scripts/internal-ca.sh "$e" >/dev/null 2>&1 || { echo "FAIL internal-ca.sh $e"; fail=$((fail + 1)); }; done

for e in dev qa main; do
  d="$tmp/$e"
  check "$e: the four files exist" sh -c "[ -s $d/ca.key ] && [ -s $d/ca.crt ] && [ -s $d/catalog.crt ] && [ -s $d/catalog.key ]"
  check "$e: the CA is named csp-internal-ca" contains "$d/ca.crt" "CN *= *csp-internal-ca"
  check "$e: the CA is a CA" contains "$d/ca.crt" "CA:TRUE"
  check "$e: the CA key is at least RSA 2048" contains "$d/ca.crt" "Public-Key: ([23][0-9][0-9][0-9] bit)"
  check "$e: the CA is valid for 1 year" sh -c "openssl x509 -in $d/ca.crt -noout -checkend $((364 * day)) && ! openssl x509 -in $d/ca.crt -noout -checkend $((366 * day))"
  check "$e: the certificate of Catalog is valid for 90 days" sh -c "openssl x509 -in $d/catalog.crt -noout -checkend $((89 * day)) && ! openssl x509 -in $d/catalog.crt -noout -checkend $((91 * day))"
  check "$e: SAN has catalog-api" contains "$d/catalog.crt" "DNS:catalog-api"
  check "$e: SAN has localhost" contains "$d/catalog.crt" "DNS:localhost"
  check "$e: the certificate is for server authentication only" contains "$d/catalog.crt" "TLS Web Server Authentication"
  check "$e: the certificate is not a CA" contains "$d/catalog.crt" "CA:FALSE"
  check "$e: the chain file holds the certificate and the CA" sh -c "[ \$(grep -c 'BEGIN CERTIFICATE' $d/catalog.crt) -eq 2 ]"
  check "$e: the chain file holds no private key" sh -c "! grep -q 'PRIVATE KEY' $d/catalog.crt $d/ca.crt"
  check "$e: the key of Catalog matches its certificate" sh -c "[ \"\$(openssl x509 -in $d/catalog.crt -noout -pubkey)\" = \"\$(openssl pkey -in $d/catalog.key -pubout)\" ]"
  check "$e: the certificate verifies against its own CA" openssl verify -CAfile "$d/ca.crt" -untrusted "$d/catalog.crt" "$d/catalog.crt"
  check "$e: the name catalog-api is accepted" openssl verify -CAfile "$d/ca.crt" -verify_hostname catalog-api "$d/catalog.crt"
  check "$e: the name localhost is accepted" openssl verify -CAfile "$d/ca.crt" -verify_hostname localhost "$d/catalog.crt"
  check "$e: another name is refused" refused openssl verify -CAfile "$d/ca.crt" -verify_hostname other.example "$d/catalog.crt"
done

check "dev certificate is refused by the CA of qa" refused openssl verify -CAfile "$tmp/qa/ca.crt" "$tmp/dev/catalog.crt"
check "qa certificate is refused by the CA of main" refused openssl verify -CAfile "$tmp/main/ca.crt" "$tmp/qa/catalog.crt"
check "main certificate is refused by the CA of dev" refused openssl verify -CAfile "$tmp/dev/ca.crt" "$tmp/main/catalog.crt"
check "the three CAs are different" sh -c "[ \$(for e in dev qa main; do openssl x509 -in $tmp/\$e/ca.crt -noout -fingerprint; done | sort -u | wc -l) -eq 3 ]"

ca_before=$(openssl x509 -in "$tmp/dev/ca.crt" -noout -fingerprint)
serial_before=$(openssl x509 -in "$tmp/dev/catalog.crt" -noout -serial)
./scripts/internal-ca.sh dev >/dev/null 2>&1
check "renewal keeps the CA" sh -c "[ '$ca_before' = \"\$(openssl x509 -in $tmp/dev/ca.crt -noout -fingerprint)\" ]"
check "renewal issues a new certificate" sh -c "[ '$serial_before' != \"\$(openssl x509 -in $tmp/dev/catalog.crt -noout -serial)\" ]"
check "the renewed certificate verifies against the same CA" openssl verify -CAfile "$tmp/dev/ca.crt" -verify_hostname catalog-api "$tmp/dev/catalog.crt"
check "an unknown environment is refused" refused ./scripts/internal-ca.sh prod
check "no environment is refused" refused ./scripts/internal-ca.sh

for f in ca.key catalog.key catalog.crt ca.crt; do check "keys/tls/dev/$f is git-ignored" git check-ignore -q "keys/tls/dev/$f"; done
for e in dev qa main; do
  f="env/$e.env.example"
  check "$e.env.example: CATALOG_BASE_URL is https" grep -q '^CATALOG_BASE_URL=https://catalog-api:8082/api/v1/catalog$' "$f"
  check "$e.env.example: gateway upstream is https" grep -q '^APP_GATEWAY_CATALOG_UPSTREAM=https://catalog-api:8082$' "$f"
  check "$e.env.example: container paths" sh -c "grep -q '^CATALOG_TLS_CERTIFICATE_FILE=/run/tls/catalog.crt$' $f && grep -q '^CATALOG_TLS_PRIVATE_KEY_FILE=/run/tls/catalog.key$' $f && grep -q '^CATALOG_TLS_CA_FILE=/run/tls/ca.crt$' $f"
  check "$e.env.example: host files" sh -c "grep -q '^CATALOG_TLS_CERTIFICATE_HOST_FILE=' $f && grep -q '^CATALOG_TLS_PRIVATE_KEY_HOST_FILE=' $f && grep -q '^CATALOG_TLS_CA_HOST_FILE=' $f"
  check "$e.env.example: no plain http to catalog" sh -c "! grep -q 'http://catalog-api' $f"
done

echo "total: $((pass + fail)), passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]

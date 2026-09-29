#!/bin/sh
# shellcheck disable=SC2016  # literal $ and backticks are intentional
# Runs config-init.sh against sample .env files and checks the rendered output.
# Usage: sh tests/render-test.sh
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HASH='$2y$05$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234'
run() { ENV_FILE="$T/env" TEMPLATE=blocky.yml BLOCKY_OUT="$T/blocky.yml" TRAEFIK_OUT="$T/traefik.yml" sh config-init.sh >/dev/null 2>&1; }
has() { grep -qF -- "$2" "$T/$1" || { echo "FAIL: $1 missing: $2"; exit 1; }; }
hasnt() { ! grep -qF -- "$2" "$T/$1" || { echo "FAIL: $1 unexpectedly contains: $2"; exit 1; }; }
rejects() { printf '%s\n' "$2" > "$T/env"; ! run || { echo "FAIL: accepted $1"; exit 1; }; }

# Full config, Cloudflare on, quoted and shell-escaped hash with CRLF line ending.
cat > "$T/env" <<EOF
DOMAIN=example.com
DOH_SECRET_PATH=0123456789abcdef0123456789abcdef
DOH_USER=ali
DOH_HASHED_PASS='$(printf '%s' "$HASH" | sed 's/\$/\\$/g')'
NEXTDNS_ID=abc123
CLOUDFLARE_PROXY=true
EOF
printf 'DOH_SUBDOMAIN=dns\r\n' >> "$T/env"
run || { echo "FAIL: valid config rejected"; exit 1; }
has blocky.yml '- "https://dns.nextdns.io/abc123"'
has blocky.yml '- "https://cloudflare-dns.com/dns-query"'
has blocky.yml 'strategy: strict'
has blocky.yml 'dns: "127.0.0.1:5353"'
[ "$(grep -n "\"https://dns.nextdns.io" "$T/blocky.yml" | cut -d: -f1)" -lt "$(grep -n "\"https://cloudflare-dns" "$T/blocky.yml" | cut -d: -f1)" ] || { echo "FAIL: NextDNS not first"; exit 1; }
has traefik.yml 'Host(`dns.example.com`) && Path(`/dns-query/0123456789abcdef0123456789abcdef`)'
has traefik.yml "- \"ali:$HASH\""
has traefik.yml 'requestHeaderName: CF-Connecting-IP'
has traefik.yml 'private-doh-cloudflare-only'
has traefik.yml 'path: /dns-query'

# Secret path only, no Cloudflare, no NextDNS.
printf 'DOMAIN=example.com\nDOH_SECRET_PATH=0123456789abcdef0123456789abcdef\n' > "$T/env"
run || { echo "FAIL: secret-path-only config rejected"; exit 1; }
hasnt traefik.yml 'basicAuth'
hasnt traefik.yml 'ipAllowList'
hasnt traefik.yml 'CF-Connecting-IP'
hasnt blocky.yml '"https://dns.nextdns.io'
has traefik.yml 'Host(`resolver.example.com`)'

rejects "no auth" 'DOMAIN=example.com'
rejects "short secret" 'DOMAIN=example.com
DOH_SECRET_PATH=short'
rejects "placeholder hash" 'DOMAIN=example.com
DOH_USER=ali
DOH_HASHED_PASS=PASTE_YOUR_RAW_HASH_HERE'
rejects "user without hash" "DOMAIN=example.com
DOH_USER=ali"
rejects "yaml injection in domain" 'DOMAIN=example.com`) || Host(`evil.com
DOH_SECRET_PATH=0123456789abcdef0123456789abcdef'
rejects "bad nextdns id" 'DOMAIN=example.com
DOH_SECRET_PATH=0123456789abcdef0123456789abcdef
NEXTDNS_ID=abc/../x'
rejects "bad cloudflare flag" 'DOMAIN=example.com
DOH_SECRET_PATH=0123456789abcdef0123456789abcdef
CLOUDFLARE_PROXY=yes'

echo "render-test: all checks passed"

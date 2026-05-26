#!/bin/bash
# Revert the mitmproxy capture setup.
# - Removes ANTHROPIC_BASE_URL / NODE_EXTRA_CA_CERTS from launchctl env
# - Removes mitmproxy CA from System keychain
# - Stops any running mitmweb/mitmdump
set -u
echo "=== unsetting launchctl env vars ==="
launchctl unsetenv ANTHROPIC_BASE_URL 2>&1 || true
launchctl unsetenv NODE_EXTRA_CA_CERTS 2>&1 || true
echo "=== killing mitmweb / mitmdump ==="
pkill -f 'mitmweb|mitmdump' 2>&1 || true
echo "=== removing mitmproxy CA from System keychain (asks for sudo) ==="
sudo security delete-certificate -c mitmproxy /Library/Keychains/System.keychain 2>&1 || \
  echo "(cert may have already been removed)"
echo "=== done. Restart Xcode to fully clear inherited env. ==="

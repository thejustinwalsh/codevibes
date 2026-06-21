#!/usr/bin/env bash
# Cloud-init INTEGRATION test (the verification we were missing).
#
# Boots a fresh OrbStack Ubuntu machine with the REAL rendered cloud-init as
# user-data, waits for cloud-init to finish, and asserts the host ended up
# correctly provisioned. This executes the actual runcmd/write_files end-to-end —
# catching the class of bugs (ufw syntax, sshd hardening, user/linger, clone,
# unit install) that unit-tier tests (yamllint/render/<32KiB) cannot.
#
# Requires: OrbStack (`orb`/`orbctl`). Run from anywhere: bash deploy/tests/cloud-init-integration.sh
#
# Notes / scope:
#  - fetch-secrets.sh and deploy.sh need a live Cloudflare broker + ghcr; with the
#    dummy token here they fail gracefully (cloud-init continues). This test verifies
#    HOST PROVISIONING. The pod/app bring-up is validated separately against real
#    images (see DECISIONS-LOG "Pod bring-up validated in OrbStack").
#  - SSH key injection is distro/Hetzner-specific; here we just assert the `users:`
#    block didn't suppress key handling (an authorized_keys file exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MACHINE="${1:-codevibes-ci-verify}"
IMAGE="${CI_IMAGE:-ubuntu:26.04}"

vars="$(mktemp)"; out="$(mktemp -t ci-XXXX).yaml"
trap 'rm -f "$vars" "$out"; orbctl delete -f "$MACHINE" >/dev/null 2>&1 || true' EXIT
cat > "$vars" <<EOF
CF_SERVICE_TOKEN_ID=dummy.access
CF_SERVICE_TOKEN_SECRET=dummy
FORK_REPO=thejustinwalsh/codevibes
TUNNEL_ID=00000000-0000-0000-0000-000000000000
EOF
bash "$ROOT/deploy/gen-cloud-init.sh" "$vars" "$out" >/dev/null

orbctl delete -f "$MACHINE" >/dev/null 2>&1 || true
echo "[ci-int] booting $MACHINE ($IMAGE) with rendered cloud-init..."
orb create "$IMAGE" "$MACHINE" -c "$out"
orb -m "$MACHINE" -u root cloud-init status --wait >/dev/null 2>&1 || true

fail=0
check() { # name  remote-test-command
  if orb -m "$MACHINE" -u root bash -c "$2" >/dev/null 2>&1; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"; fail=1
  fi
}
checkfile() { # name  grep-pattern   (static check on the rendered cloud-init)
  if grep -qF -- "$2" "$out"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}
echo "[ci-int] asserting host state (effective config on the booted machine):"
check "ufw allows 22/tcp"                 "ufw status | grep -qE '22/tcp .*ALLOW'"
# sshd -T prints the EFFECTIVE merged config (handles sshd_config.d/*.conf drop-ins).
check "sshd permitrootlogin prohibit-pw"  "sshd -T 2>/dev/null | grep -qi '^permitrootlogin prohibit-password'"
check "sshd passwordauthentication no"    "sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'"
check "fail2ban active"                   "systemctl is-active --quiet fail2ban"
check "codevibes user exists"             "id codevibes"
check "linger enabled for codevibes"      "loginctl show-user codevibes -p Linger 2>/dev/null | grep -q Linger=yes"
check "repo cloned (production)"          "test -d /home/codevibes/codevibes/deploy"
check "deploy scripts are executable"     "test -x /home/codevibes/codevibes/deploy/fetch-secrets.sh && test -x /home/codevibes/codevibes/deploy/deploy.sh && test -x /home/codevibes/codevibes/deploy/render-config.sh"
check "quadlet units installed"           "test -f /home/codevibes/.config/containers/systemd/codevibes-backend.container"
check "deploy timer units present"        "test -f /home/codevibes/.config/systemd/user/codevibes-deploy.timer"

echo "[ci-int] asserting key mechanism (static — OrbStack injects no cloud-init SSH key, Hetzner does):"
checkfile "users: includes '- default' (preserves platform key injection)"  "- default"
checkfile "key-copy to codevibes present"                                    "/home/codevibes/.ssh/authorized_keys"

if [ "$fail" -eq 0 ]; then echo "[ci-int] ALL CHECKS PASSED"; else echo "[ci-int] FAILURES ABOVE"; fi
exit "$fail"

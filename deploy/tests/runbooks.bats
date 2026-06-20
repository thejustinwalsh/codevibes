#!/usr/bin/env bats
# I1 — runbooks self-contained HTML test (must fail before runbooks are authored/rendered)
R="${BATS_TEST_DIRNAME}/../../docs/runbooks"

@test "all four runbooks render to self-contained html" {
  for f in cloudflare-zerotrust cloudflare-secrets setup recovery; do
    [ -f "$R/$f.html" ]
    grep -qi "<style" "$R/$f.html"            # inline CSS
    ! grep -qiE 'src="https?://|href="https?://[^"]+\.css' "$R/$f.html"  # no external assets
  done
}

@test "recovery runbook covers rollback, secret re-fetch, volume reattach, restore" {
  grep -qi "rollback" "$R/recovery.html"
  grep -qi "fetch-secrets" "$R/recovery.html"
  grep -qi "reattach" "$R/recovery.html"
  grep -qi "restore" "$R/recovery.html"
}

@test "secrets runbook warns ENCRYPTION_KEY is never regenerated" {
  grep -qi "never" "$R/cloudflare-secrets.html"
  grep -qi "ENCRYPTION_KEY" "$R/cloudflare-secrets.html"
}

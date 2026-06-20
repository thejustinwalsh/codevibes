#!/usr/bin/env bats
# Integration consistency assertions: cross-file agreement across workstreams A-H.
# These tests do NOT fix mismatches — they report them so the source can be corrected.
ROOT="${BATS_TEST_DIRNAME}/../.."

load_cfg() {
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/deploy/config.env"
  set +a
}

# ---------------------------------------------------------------------------
# J1: Quadlet secret names match deploy/config.env
# Verify: the literal secret names defined in config.env appear in the quadlet
# units that consume them.
# ---------------------------------------------------------------------------
@test "quadlet secret names match config.env" {
  load_cfg
  grep -q "$SECRET_JWT"    "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "$SECRET_ENCKEY" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "$SECRET_TUNNEL" "$ROOT/deploy/quadlet/codevibes-cloudflared.container"
  grep -q "$SECRET_GH_ID"     "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "$SECRET_GH_SECRET" "$ROOT/deploy/quadlet/codevibes-backend.container"
}

# ---------------------------------------------------------------------------
# J2: fetch-secrets.sh creates exactly the secrets the quadlet units consume.
#
# fetch-secrets.sh sources config.env and uses the SECRET_* variables (not
# literal names), so we check two things:
#   (a) fetch-secrets.sh references each config.env variable by its variable
#       name — confirming it uses config.env as the single source of truth.
#   (b) The literal secret name each variable expands to appears in a quadlet
#       unit — confirming the quadlet side is consistent with config.env.
# ---------------------------------------------------------------------------
@test "fetch-secrets creates exactly the secrets quadlet consumes" {
  load_cfg

  # (a) fetch-secrets.sh uses every SECRET_* variable from config.env
  grep -q 'SECRET_JWT'    "$ROOT/deploy/fetch-secrets.sh"
  grep -q 'SECRET_ENCKEY' "$ROOT/deploy/fetch-secrets.sh"
  grep -q 'SECRET_GH_ID'     "$ROOT/deploy/fetch-secrets.sh"
  grep -q 'SECRET_GH_SECRET' "$ROOT/deploy/fetch-secrets.sh"
  grep -q 'SECRET_TUNNEL' "$ROOT/deploy/fetch-secrets.sh"

  # (b) Each expanded secret name appears somewhere in the quadlet directory
  grep -Rq "$SECRET_JWT"       "$ROOT/deploy/quadlet/"
  grep -Rq "$SECRET_ENCKEY"    "$ROOT/deploy/quadlet/"
  grep -Rq "$SECRET_GH_ID"     "$ROOT/deploy/quadlet/"
  grep -Rq "$SECRET_GH_SECRET" "$ROOT/deploy/quadlet/"
  grep -Rq "$SECRET_TUNNEL"    "$ROOT/deploy/quadlet/"
}

# ---------------------------------------------------------------------------
# J3: Image names consistent across deploy/deploy.sh, build.yml, and quadlet.
# ---------------------------------------------------------------------------
@test "image names are consistent across deploy.sh, build.yml, and quadlet" {
  # deploy.sh hardcodes the local tag targets (built from IMAGE_BACKEND/IMAGE_WEB)
  grep -q "codevibes-backend" "$ROOT/deploy/deploy.sh"
  grep -q "codevibes-web"     "$ROOT/deploy/deploy.sh"

  # build.yml pushes images named codevibes-backend and codevibes-web
  grep -q "codevibes-backend" "$ROOT/.github/workflows/build.yml"
  grep -q "codevibes-web"     "$ROOT/.github/workflows/build.yml"

  # quadlet units pull the floating :current tags
  grep -q "codevibes-backend:current" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "codevibes-web:current"     "$ROOT/deploy/quadlet/codevibes-web.container"
}

# ---------------------------------------------------------------------------
# J4: App domain (single origin) is consistent across Dockerfile.web,
#     the backend quadlet unit, and the cloudflared tunnel config template.
# ---------------------------------------------------------------------------
@test "app domain is consistent (single origin codevibes.tjw.dev)" {
  grep -q "codevibes.tjw.dev" "$ROOT/Dockerfile.web"
  grep -q "codevibes.tjw.dev" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "codevibes.tjw.dev" "$ROOT/deploy/cloudflared/config.yml.template"
}

# ---------------------------------------------------------------------------
# J5: Plain systemd timers (.timer/.service) are installed to
#     ~/.config/systemd/user — not to the quadlet containers/systemd dir.
#     Verified via cloud-init.template.yaml, which is the installer.
# ---------------------------------------------------------------------------
@test "plain systemd timers are installed to the user systemd dir, not quadlet dir" {
  grep -q ".config/systemd/user" "$ROOT/deploy/cloud-init.template.yaml"
  # The cloud-init must copy *.timer and *.service to systemd/user (not containers/systemd)
  grep -q '\.timer.*\.config/systemd/user\|\.config/systemd/user.*\.timer' \
    "$ROOT/deploy/cloud-init.template.yaml"
}

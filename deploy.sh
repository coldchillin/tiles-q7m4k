#!/usr/bin/env bash
#
# deploy.sh — publish the newest ~/Downloads/index*.html to GitHub Pages.
#
# Usage:  ./deploy.sh "<commit message>" <version>
# Example: ./deploy.sh "v12: nicer tiles" v12
#
# Steps: pull -> pick newest download -> gate on the app-version meta tag ->
# copy over index.html -> commit (index.html only) -> push -> wait for the
# Pages deployment -> curl-verify the live page.
#
# Bails out before touching anything if the gate fails, so a wrong or stale
# download can't be published.
#
# Env overrides:
#   DOWNLOADS_DIR   where to look for index*.html   (default: ~/Downloads)
#   SITE_URL        live URL to verify              (default: derived from origin)

set -euo pipefail

die()  { printf '\n\033[31mERROR\033[0m  %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- args
[ $# -eq 2 ] || die "usage: $(basename "$0") \"<commit message>\" <version>
       e.g. $(basename "$0") \"v12: nicer tiles\" v12"

MSG="$1"
VERSION="v${2#v}"          # accept both "12" and "v12"
[ -n "$MSG" ] || die "commit message must not be empty"
[[ "$VERSION" =~ ^v[0-9]+$ ]] || die "version must look like v12 (got '$2')"

DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Downloads}"
GATE="name=\"app-version\" content=\"$VERSION\""

# ------------------------------------------------------- repo + tooling
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)" \
  || die "deploy.sh must live inside the git repo"
cd "$REPO_ROOT"

command -v gh   >/dev/null || die "the GitHub CLI (gh) is required: brew install gh"
command -v curl >/dev/null || die "curl is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated: run 'gh auth login'"

SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [ -z "${SITE_URL:-}" ]; then
  SITE_URL="https://${SLUG%%/*}.github.io/${SLUG##*/}/"
fi
info "repo: $SLUG"
info "site: $SITE_URL"

# ------------------------------------------------------------ 1. pull
step "Pulling latest main"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = main ] || die "on branch '$BRANCH', expected main"

# Warn about unrelated local edits; we only ever stage index.html, so they
# stay in the working tree rather than sneaking into the commit.
OTHER_DIRTY="$(git status --porcelain -- . ':(exclude)index.html' | sed 's/^/      /')"
if [ -n "$OTHER_DIRTY" ]; then
  printf '    \033[33m!\033[0m other files have local changes (they will NOT be committed):\n%s\n' "$OTHER_DIRTY"
fi

git pull --ff-only --quiet || die "git pull failed — resolve it by hand, then re-run"
ok "up to date with origin/main ($(git rev-parse --short HEAD))"

# -------------------------------------------- 2. newest download + gate
step "Finding newest $DOWNLOADS_DIR/index*.html"
[ -d "$DOWNLOADS_DIR" ] || die "no such directory: $DOWNLOADS_DIR"

SRC="$(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -name 'index*.html' \
         -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "$SRC" ] || die "no files matching $DOWNLOADS_DIR/index*.html"
info "picked: $SRC"
info "        $(wc -c < "$SRC" | tr -d ' ') bytes, modified $(stat -f '%Sm' "$SRC")"

step "Checking version gate: $GATE"
if ! grep -qF "$GATE" "$SRC"; then
  FOUND="$(grep -o -E '<meta[^>]*app-version[^>]*>' "$SRC" || true)"
  die "gate FAILED — nothing copied, nothing committed.
       expected: <meta $GATE>
       found:    ${FOUND:-(no app-version meta tag at all)}
       This usually means the wrong or a stale file was picked. Re-export, then re-run."
fi
ok "$VERSION confirmed in source file"

# ------------------------------------------------------------ 3. copy
step "Copying over index.html"
cp "$SRC" index.html
grep -qF "$GATE" index.html || die "gate missing after copy — aborting (copy went wrong)"

if git diff --quiet -- index.html; then
  printf '\n\033[33mNothing to do:\033[0m index.html is already identical to that download.\n'
  info "HEAD is $(git rev-parse --short HEAD); $SITE_URL should already serve $VERSION."
  exit 0
fi
git diff --stat -- index.html | sed 's/^/    /'

# ------------------------------------------------- 4. commit and push
step "Committing and pushing"
git add -- index.html
git commit --quiet -m "$MSG" -- index.html
SHA="$(git rev-parse HEAD)"
ok "committed $(git rev-parse --short HEAD) — $MSG"

# Prove we only touched index.html.
TOUCHED="$(git show --name-only --format= HEAD | grep -v '^$' || true)"
[ "$TOUCHED" = "index.html" ] || die "commit touched unexpected files:
$TOUCHED"
ok "commit contains index.html only"

git push --quiet origin main
ok "pushed to origin/main"

# ------------------------------------------- 5. wait for Pages deploy
step "Waiting for the GitHub Pages deployment"
RUN_ID=""
for _ in $(seq 1 20); do
  RUN_ID="$(gh run list --workflow pages-build-deployment -L 10 \
              --json databaseId,headSha \
              --jq "map(select(.headSha==\"$SHA\")) | .[0].databaseId // empty")"
  [ -n "$RUN_ID" ] && break
  sleep 3
done
[ -n "$RUN_ID" ] || die "no Pages run appeared for $SHA after ~60s. The push succeeded;
       check $(printf 'https://github.com/%s/actions' "$SLUG")"
info "run $RUN_ID"

gh run watch "$RUN_ID" --exit-status --interval 10 >/dev/null 2>&1 \
  || die "the Pages deployment failed. The commit is pushed; see
       $(printf 'https://github.com/%s/actions/runs/%s' "$SLUG" "$RUN_ID")"
ok "workflow completed successfully"

BUILD="$(gh api "repos/$SLUG/pages/builds" \
          --jq '.[0] | "\(.status) \(.commit) \(.error.message // "none")"')"
read -r B_STATUS B_COMMIT B_ERROR <<<"$BUILD"
[ "$B_STATUS" = built ] || die "Pages build status is '$B_STATUS' (error: $B_ERROR)"
[ "$B_COMMIT" = "$SHA" ] || die "Pages built $B_COMMIT but we pushed $SHA"
ok "Pages built ${SHA:0:7}"

# ----------------------------------------------- 6. verify the live URL
step "Verifying the live page"
TMP="$(mktemp -t deploy-live)"
trap 'rm -f "$TMP"' EXIT

HDRS="$(curl -fsS -D - -o "$TMP" \
          -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
          "${SITE_URL}?cb=${SHA:0:7}")" \
  || die "could not fetch $SITE_URL"
printf '%s\n' "$HDRS" | grep -iE '^(HTTP/|last-modified|age|x-cache):' | sed 's/^/    /'

grep -qF "$GATE" "$TMP" || die "live page does not contain <meta $GATE>.
       The deploy reported success, so this is most likely CDN caching —
       wait a minute and re-run the check:
         curl -s '${SITE_URL}?cb=\$(date +%s)' | grep -o '<meta[^>]*app-version[^>]*>'"
ok "live page contains $VERSION"

if cmp -s "$TMP" index.html; then
  ok "live page is byte-identical to index.html ($(wc -c < "$TMP" | tr -d ' ') bytes)"
else
  printf '    \033[33m!\033[0m live page contains %s but differs byte-wise from local index.html\n' "$VERSION"
  info "likely a stale CDN edge copy; re-run the curl above in a minute"
fi

# ------------------------------------------------------------- summary
printf '\n\033[32mDeployed %s\033[0m\n' "$VERSION"
printf '  commit  %s  %s\n' "$(git rev-parse --short HEAD)" "$MSG"
printf '  version %s\n' "$VERSION"
printf '  live    %s\n\n' "$SITE_URL"
printf 'Your browser may still show an older build (sw.js caches index.html).\n'
printf 'Hard-reload, then confirm in the console:\n'
printf "  document.querySelector('meta[name=app-version]').content\n"

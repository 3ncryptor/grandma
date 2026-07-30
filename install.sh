#!/usr/bin/env bash
# grandma installer:  curl -fsSL https://raw.githubusercontent.com/anshulforyou/grandma/master/install.sh | bash
set -euo pipefail
REPO="${GRANDMA_REPO:-https://github.com/anshulforyou/grandma.git}"
DEST="${GRANDMA_ENGINE:-$HOME/.grandma-engine}"

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }
if [[ -d "$DEST/.git" ]]; then
  # `grandma update`, not a raw pull: it lands on the tracked branch even when this checkout sits on
  # some other one, and it refuses instead of trampling local work. A refusal is not fatal here,
  # since init below is still worth running against the engine as it stands.
  "$DEST/bin/grandma" update || echo "  the engine was left as it is. Fix the above, then run: grandma update"
else
  echo "installing grandma engine to $DEST"
  git clone --depth 1 "$REPO" "$DEST"
fi
exec "$DEST/bin/grandma" init

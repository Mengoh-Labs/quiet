#!/bin/bash
# No live inference or model downloads. Terminal signal tests own their children.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-environment.sh
quiet_python="${QUIET_TEST_PYTHON:-python3}"
"$quiet_python" -c 'import pyte'
quiet_checks="$(mktemp -d "$TMPDIR/quiet-checks.XXXXXX")"
trap 'rm -rf "$quiet_checks"' EXIT
export QUIET_SUPPORT_DIR="$quiet_checks/support"
export QUIET_AGENT_HOME="$quiet_checks/agents"
export QUIET_CHAT_DIR="$quiet_checks/chat"
export QUIET_AMBIENT=off
export QUIET_RENDERER=text
mkdir -p "$QUIET_SUPPORT_DIR" "$QUIET_AGENT_HOME" "$QUIET_CHAT_DIR"
swift test --cache-path "$PWD/.build/cache" -j 2
bash scripts/build-app.sh
bash scripts/build-cli.sh
quiet_cli="$PWD/dist/quiet-cli/quiet"
"$quiet_cli" --help > "$quiet_checks/help.txt"
grep -q 'quiet dashboard' "$quiet_checks/help.txt"
"$quiet_cli" --version
"$quiet_python" scripts/check-terminal.py "$quiet_cli"
"$quiet_python" scripts/check-terminal-jobcontrol.py "$quiet_cli"
"$quiet_python" scripts/check-terminal-layout.py "$quiet_cli"
"$quiet_python" scripts/check-agents.py "$quiet_cli"
"$quiet_python" - <<'PY'
from pathlib import Path
root = Path.cwd().parent
for destination in [root/'native/dist/Quiet.app/Contents/Resources', root/'native/dist/quiet-cli']:
    for name in ['LICENSE', 'LICENSE-ASSETS.md', 'LICENSE-ARTWORK', 'THIRD_PARTY_NOTICES.md']:
        assert (destination/name).read_bytes() == (root/name).read_bytes(), name
    notices = [path for path in (root/'LICENSES').rglob('*') if path.is_file()]
    assert notices, 'Dependency license texts are missing'
    for path in notices:
        assert (destination/path.relative_to(root)).read_bytes() == path.read_bytes(), str(path)
print('App and standalone CLI license texts match source byte-for-byte.')
PY

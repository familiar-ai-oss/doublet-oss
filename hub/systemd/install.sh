#!/usr/bin/env bash
# Run on the hub machine from ~/duet-hub (make install-hub does this after deploy-hub).
# Installs the user unit with node's absolute path, enables it, and adds the tailnet mapping :8443 -> 7811.
set -euo pipefail
cd "$(dirname "$0")/.."

node=$(command -v node)
# fnm/nvm shims live in per-shell temp dirs; pin the real binary instead.
case "$node" in *fnm_multishells*|*/run/user/*) node=$(readlink -f "$node") ;; esac
"$node" -e 'const [a,b]=process.versions.node.split(".").map(Number); if (a<22||(a===22&&b<18)) { console.error(`node ${process.version} is too old; need >= 22.18`); process.exit(1) }'
echo "node: $node ($("$node" -v))"

unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"
sed "s|@NODE@|$node|" systemd/duet-hub.service > "$unit_dir/duet-hub.service"
cp systemd/duet-commands.slice "$unit_dir/duet-commands.slice"
systemctl --user daemon-reload
# --now starts it if stopped; a running hub keeps its code until make restart-hub (never mid-turn).
systemctl --user enable --now duet-hub.service
systemctl --user --no-pager --lines=0 status duet-hub | head -5 || true

[ "$(loginctl show-user "$USER" -p Linger --value)" = yes ] \
  || echo "WARNING: lingering is off, so the hub stops at logout. Run: sudo loginctl enable-linger $USER"

# Tailnet mapping. Only port 8443 is touched; other serve mappings must come out unchanged.
others() { tailscale serve status --json | "$node" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s||"{}");const o={TCP:{},Web:{}};for(const [k,v] of Object.entries(j.TCP||{}))if(k!=="8443")o.TCP[k]=v;for(const [k,v] of Object.entries(j.Web||{}))if(!k.endsWith(":8443"))o.Web[k]=v;console.log(JSON.stringify(o))})'; }
before=$(others)
tailscale serve --bg --https=8443 http://127.0.0.1:7811 >/dev/null
after=$(others)
if [ "$before" != "$after" ]; then echo "ERROR: other tailscale serve mappings changed" >&2; echo "before: $before" >&2; echo "after:  $after" >&2; exit 1; fi
echo "tailscale serve: https://$(tailscale status --json | "$node" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).Self.DNSName.replace(/\.$/,"")))'):8443 -> 127.0.0.1:7811 (other mappings unchanged)"

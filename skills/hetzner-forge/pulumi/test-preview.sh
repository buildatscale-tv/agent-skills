#!/usr/bin/env bash
# Confirm Pulumi runs in YOUR terminal. It hangs inside the agent sandbox (which blocks the
# engine<->plugin loopback gRPC), so run this from a normal Terminal window, not via the agent.
# Success = it prints a plan (create ssh-key + firewall + server). It creates NOTHING.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/bin:$HOME/.cargo/bin:$HOME/.opencode/bin:$PATH"
export PULUMI_BACKEND_URL="file://$HOME/.pulumi-forge-test"      # local state, no Pulumi Cloud
export PULUMI_CONFIG_PASSPHRASE="forge-test"
mkdir -p "$HOME/.pulumi-forge-test"

[ -d node_modules ] || npm install
pulumi stack select test 2>/dev/null || pulumi stack init test

# provider token from the active hcloud context
TOKEN=$(python3 -c "import tomllib,os;d=tomllib.load(open(os.path.expanduser('~/.config/hcloud/cli.toml'),'rb'));a=d['active_context'];print(next(c['token'] for c in d['contexts'] if c['name']==a))")
pulumi config set hcloud:token "$TOKEN" --secret
pulumi config set sshPublicKey "$(cat ~/.ssh/id_hetzner_ed25519.pub)"
pulumi config set name forge-test
pulumi config set location hil
pulumi config set serverType cpx21

echo "=== pulumi preview (expect a plan of ~3 resources; if it hangs >60s it's not the sandbox) ==="
pulumi preview

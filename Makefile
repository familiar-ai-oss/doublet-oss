# Doublet build and deploy. The hub runs on a machine you reach over ssh: set HOST (its ssh alias) in local.mk
# (git-ignored; see local.mk.example) or on the command line.
-include local.mk
HOST ?= $(error set HOST, the hub machine's ssh alias, in local.mk or as make HOST=...)
HUB_DIR ?= duet-hub

.PHONY: typecheck deploy-hub test-hub install-hub restart-hub hub-logs uninstall-hub fixtures leakcheck leakcheck-hook

typecheck:
	cd hub && npx tsc --noEmit

# Copy the hub to the hub machine and install exact dependencies. The running service keeps its old code until `make restart-hub`.
deploy-hub: typecheck
	rsync -a --delete --exclude node_modules hub/ $(HOST):$(HUB_DIR)/
	ssh $(HOST) 'bash -lc "cd $(HUB_DIR) && npm ci --no-audit --no-fund --loglevel=error"'

# Phase 1 check against the real Claude login on the hub machine. It runs its own hub on a random port with its own state
# dir, so the service is not disturbed.
test-hub: deploy-hub
	ssh $(HOST) 'bash -lc "cd $(HUB_DIR) && npm test"'

# Install duet-hub as a systemd user service (see docs/deploy.md), plus the tailnet mapping :8443 -> 7811.
install-hub: deploy-hub
	ssh $(HOST) 'bash -lc "cd $(HUB_DIR) && systemd/install.sh"'

# Restart the service to pick up deployed code. Refuses while the lead is busy (mid-turn or prompts queued).
restart-hub:
	ssh $(HOST) 'bash -lc "$(HUB_DIR)/systemd/restart.sh"'

hub-logs:
	ssh -t $(HOST) 'journalctl --user -u duet-hub -f'

# Stop and remove the service and the :8443 mapping. Keeps the event log, lead session and device tokens.
uninstall-hub:
	ssh $(HOST) 'systemctl --user disable --now duet-hub; rm -f ~/.config/systemd/user/duet-hub.service; systemctl --user daemon-reload; tailscale serve --https=8443 off'

# Record protocol fixtures from a real hub run on the hub machine (the Swift tests decode these).
fixtures: deploy-hub
	ssh $(HOST) 'bash -lc "rm -rf /tmp/duet-fixtures && cd $(HUB_DIR) && DUET_FIXTURES_DIR=/tmp/duet-fixtures npm test"'
	rm -rf protocol/fixtures && mkdir -p protocol/fixtures
	rsync -a $(HOST):/tmp/duet-fixtures/ protocol/fixtures/
	ssh $(HOST) 'rm -rf /tmp/duet-fixtures'

# Check that nothing about to be published holds a secret or one of your values (tools/leakcheck.sh).
leakcheck:
	tools/leakcheck.sh

# Run the leak check before every commit.
leakcheck-hook:
	ln -sf ../../tools/leakcheck.sh .git/hooks/pre-commit

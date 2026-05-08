.DEFAULT_GOAL := help

# Worktree detection: directory name becomes the project name
WORKTREE_NAME := $(notdir $(CURDIR))
MAIN_NAME := specled_ex

# GNU make executes recipe lines that reference the special $(MAKE) variable
# even under -n/--dry-run. Use this alias for recursive invocations so dry-run
# stays side-effect free for worktree/bootstrap targets.
RECURSIVE_MAKE := $(MAKE)

.PHONY: help clean deps format test compile check \
	worktree-new worktree-bootstrap worktree-info worktree-status \
	worktree-cleanup worktree-cleanup-all smoke \
	wts wti wtn wtb wtc wtca

define SPECLED
------------------------------
          specled
------------------------------
endef
export SPECLED

# General
help: ## Show this help
	@echo "$$SPECLED"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

clean: ## Remove build artifacts
	rm -rf _build deps

deps: ## Install dependencies
	mix deps.get

format: ## Format the project
	mix format

test: ## Run the test suite
	mix test

compile: ## Compile with warnings-as-errors
	mix compile --warnings-as-errors

check: ## Run the spec verification gate
	mix spec.check

# Worktree workflow
worktree-info: ## Display current worktree configuration
	@echo "Worktree Name: $(WORKTREE_NAME)"
	@echo "Worktree Path: $(CURDIR)"
	@if [ "$(WORKTREE_NAME)" = "$(MAIN_NAME)" ]; then \
		echo "Mode:          MAIN CHECKOUT (do not commit from here)"; \
	else \
		echo "Mode:          worktree"; \
	fi
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null); \
	echo "Branch:        $$BRANCH"

worktree-new: ## Create + fully bootstrap a new worktree from this checkout. Usage: make worktree-new BRANCH=feature/x
	@if [ -z "$(BRANCH)" ]; then echo "Usage: make worktree-new BRANCH=feature/my-feature"; exit 1; fi
	@SLUG=$$(echo "$(BRANCH)" | sed 's|.*/||; s|[^a-zA-Z0-9]|-|g'); \
	DIR="../$(MAIN_NAME)-$$SLUG"; \
	echo "━━━ Creating worktree at $$DIR for branch $(BRANCH) from $(WORKTREE_NAME) ━━━"; \
	git worktree add "$$DIR" -b "$(BRANCH)" && \
	$(RECURSIVE_MAKE) -C "$$DIR" worktree-bootstrap

worktree-bootstrap: ## Idempotent standup: deps + compile + smoke.
	@if [ "$(WORKTREE_NAME)" = "$(MAIN_NAME)" ]; then \
		echo "Error: worktree-bootstrap must be run from a worktree, not the main checkout"; \
		exit 1; \
	fi
	@echo "━━━ Bootstrap: $(WORKTREE_NAME) ━━━"
	@echo "→ Fetching dependencies..."
	@mix deps.get
	@echo "→ Compiling (warnings-as-errors)..."
	@mix compile --warnings-as-errors
	@$(RECURSIVE_MAKE) smoke

smoke: ## Verify this worktree: mix.exs present, deps populated, build green
	@echo "━━━ Smoke: $(WORKTREE_NAME) ━━━"
	@fail=0; \
	printf "  mix.exs        ... "; \
	if [ -f mix.exs ]; then \
		printf "\033[32m✓\033[0m\n"; \
	else \
		printf "\033[31m✗\033[0m missing\n"; fail=1; \
	fi; \
	printf "  deps populated ... "; \
	if [ -d deps ] && [ -n "$$(ls -A deps 2>/dev/null)" ]; then \
		printf "\033[32m✓\033[0m\n"; \
	else \
		printf "\033[31m✗\033[0m run 'mix deps.get'\n"; fail=1; \
	fi; \
	printf "  _build present ... "; \
	if [ -d _build ]; then \
		printf "\033[32m✓\033[0m\n"; \
	else \
		printf "\033[31m✗\033[0m run 'mix compile'\n"; fail=1; \
	fi; \
	printf "  compile clean  ... "; \
	if mix compile --warnings-as-errors >/dev/null 2>&1; then \
		printf "\033[32m✓\033[0m\n"; \
	else \
		printf "\033[31m✗\033[0m 'mix compile --warnings-as-errors' failed\n"; fail=1; \
	fi; \
	echo ""; \
	if [ $$fail -ne 0 ]; then \
		printf "\033[31m✗ SMOKE FAILED\033[0m — run 'make worktree-bootstrap' to repair\n"; \
		exit 1; \
	else \
		printf "\033[32m✓ READY\033[0m at $(CURDIR)\n"; \
	fi

worktree-status: ## Show all worktrees with git status
	@printf "\n  \033[1m%-42s %-44s %s\033[0m\n\n" "WORKTREE" "BRANCH" "GIT"; \
	git worktree list --porcelain | awk '/^worktree /{path=$$2} /^branch /{branch=$$2; print path "\t" branch}' | \
	while IFS=$$'\t' read -r wpath branch; do \
		name=$$(basename "$$wpath"); \
		short_branch=$$(echo "$$branch" | sed 's|refs/heads/||'); \
		dirty=$$(git -C "$$wpath" status --porcelain 2>/dev/null | wc -l | tr -d ' '); \
		ahead=$$(git -C "$$wpath" rev-list main..HEAD --count 2>/dev/null || echo "?"); \
		ahead_origin=$$(git -C "$$wpath" rev-list origin/main..HEAD --count 2>/dev/null || echo "?"); \
		if [ "$$ahead" != "$$ahead_origin" ] && [ "$$ahead_origin" -gt "$$ahead" ] 2>/dev/null; then \
			ahead="$$ahead_origin"; \
		fi; \
		git_info=""; \
		if [ "$$short_branch" = "main" ]; then \
			marker="\033[34m●\033[0m"; \
			if [ "$$dirty" -gt 0 ]; then git_info="\033[33m$$dirty dirty\033[0m"; else git_info="\033[90mclean\033[0m"; fi; \
		else \
			marker="\033[32m●\033[0m"; \
			if [ "$$ahead" = "0" ]; then \
				if [ "$$dirty" = "0" ]; then \
					git_info="\033[32mmerged\033[0m"; \
				else \
					git_info="\033[32mmerged\033[0m, \033[33m$$dirty dirty\033[0m"; \
				fi; \
			else \
				git_info="\033[36m$$ahead unmerged\033[0m"; \
				if [ "$$dirty" -gt 0 ]; then \
					git_info="$$git_info, \033[33m$$dirty dirty\033[0m"; \
				fi; \
			fi; \
		fi; \
		printf "  $$marker %-41s %-44s %b\n" "$$name" "$$short_branch" "$$git_info"; \
	done; \
	echo ""

worktree-cleanup: ## Remove a single worktree by NAME=<name>; refuses if unmerged or dirty.
	@if [ -z "$(NAME)" ]; then \
		echo "Usage:"; \
		echo "  make worktree-cleanup NAME=<worktree-name>   Remove one worktree"; \
		echo "  make worktree-cleanup-all                    Remove every fully-merged worktree"; \
		exit 1; \
	fi
	@bash .claude/scripts/worktree-cleanup.sh --name "$(NAME)"

worktree-cleanup-all: ## Remove every worktree whose branch is fully merged into main.
	@bash .claude/scripts/worktree-cleanup.sh --all

# Aliases
wts: worktree-status ## Alias for worktree-status
wti: worktree-info ## Alias for worktree-info
wtn: worktree-new ## Alias for worktree-new
wtb: worktree-bootstrap ## Alias for worktree-bootstrap
wtc: worktree-cleanup ## Alias for worktree-cleanup (requires NAME=)
wtca: worktree-cleanup-all ## Alias for worktree-cleanup-all

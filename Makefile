.PHONY: lint format test ci help

help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Run shellcheck on all bash scripts
	shellcheck *.sh

format: ## Run shfmt to format all bash scripts
	shfmt -w -i 2 -ci *.sh

format-check: ## Check if bash scripts are formatted correctly (used in CI)
	shfmt -d -i 2 -ci *.sh

test: ## Run BATS automated tests
	bats tests/

ci: lint format-check test ## Run all CI checks locally

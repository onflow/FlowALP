.PHONY: lint
lint:
	@output=$$(flow cadence lint $$(find cadence -name "*.cdc") 2>&1); \
	echo "$$output"; \
	if echo "$$output" | grep -qE "[1-9][0-9]* problems"; then \
		echo "Lint failed: problems found"; \
		exit 1; \
	fi

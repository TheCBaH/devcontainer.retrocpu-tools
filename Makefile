.PHONY: submodule
submodule:
	git -c safe.directory="$(CURDIR)" -c safe.directory="$(CURDIR)/*" submodule update --init --depth 1

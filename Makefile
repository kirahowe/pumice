EMACS ?= emacs
# Directories of optional packages to test against, such as evil or consult.
# The tests that need one are skipped when it is not on the load path.
DEPS ?=
BATCH = $(EMACS) --batch -Q -L . $(addprefix -L ,$(DEPS))
SOURCES = $(wildcard pumice*.el)
# package-vc compiles every file in the checkout, so these have to be
# clean as well.
EXTRAS = test/pumice-test.el $(wildcard contrib/spacemacs/pumice/*.el)

.PHONY: all test compile checkdoc clean

all: compile test

test:
	$(BATCH) -l test/pumice-test.el -f ert-run-tests-batch-and-exit

# Warnings are errors, so a new one cannot slip in.
compile: clean
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SOURCES) $(EXTRAS)

checkdoc:
	$(BATCH) --eval '(dolist (file command-line-args-left) (checkdoc-file file))' \
	  $(SOURCES)

clean:
	rm -f *.elc test/*.elc contrib/spacemacs/pumice/*.elc

GUILE ?= guile

# Local non-secret resource defaults.  Command-line assignments still win.
-include .env

# Values loaded from .env must also be visible to the shell scripts invoked by
# Make.  Command-line overrides retain their usual higher precedence.
export ORACLE_IMAGE_FILE ORACLE_BUCKET_NAME ORACLE_OBJECT_NAME
export ORACLE_UPLOAD_PART_MIB

IMAGE_ID ?= $(ORACLE_IMAGE_ID)
SUBNET_ID ?= $(ORACLE_SUBNET_ID)
INSTANCE_ID ?= $(ORACLE_INSTANCE_ID)
EVIDENCE_DIR ?= $(ORACLE_EVIDENCE_DIR)

.PHONY: help test manifest oracle-help oracle-test oracle-auth oracle-inventory
.PHONY: oracle-instance oracle-evidence oracle-stage0 oracle-stage1
.PHONY: oracle-run-status oracle-logs oracle-collect oracle-stop oracle-cleanup oracle-handoff
.PHONY: oracle-build-generic oracle-upload-generic oracle-import-generic oracle-timings

help:
	@echo "Repository targets:"
	@echo "  make test               Run the complete local test suite"
	@echo "  make manifest           Regenerate SOURCE_MANIFEST.txt"
	@echo "  make oracle-help        Show Oracle validation targets"

test:
	./run-tests.sh

manifest:
	./update-manifest.sh

oracle-help:
	@echo "Read-only/local targets:"
	@echo "  make oracle-test"
	@echo "  make oracle-auth"
	@echo "  make oracle-inventory"
	@echo "  make oracle-timings       # historical median/p90 durations"
	@echo "  make oracle-instance      # defaults from .env"
	@echo "  make oracle-evidence      # defaults from .env"
	@echo ""
	@echo "Disposable lifecycle targets (create an IN_TEST instance):"
	@echo "  make oracle-build-generic # local x86_64 QCOW2, resumable container"
	@echo "  make oracle-upload-generic # verified multipart upload; values from .env"
	@echo "  make oracle-import-generic # resumable custom-image import and waiter"
	@echo "  make oracle-stage0        # IMAGE_ID/SUBNET_ID default from .env"
	@echo "  make oracle-stage1 COMMAND='./run-tests.sh'"
	@echo "  make oracle-run-status RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-logs RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-collect RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-stop RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-cleanup RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-handoff RUN_DIR=.oracle-validation/runs/..."
	@echo ""
	@echo "There is intentionally no generic destroy target."

oracle-test:
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-validation.scm

oracle-auth:
	$(GUILE) --no-auto-compile -s oracle/scripts/oci-inspect.scm auth

oracle-inventory:
	$(GUILE) --no-auto-compile -s oracle/scripts/oci-inspect.scm inventory

oracle-instance:
	@test -n "$(INSTANCE_ID)" || { echo "INSTANCE_ID is required" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/scripts/oci-inspect.scm instance \
		--instance-id '$(INSTANCE_ID)'

oracle-evidence:
	@test -n "$(INSTANCE_ID)" || { echo "INSTANCE_ID is required" >&2; exit 2; }
	@test -n "$(EVIDENCE_DIR)" || { echo "EVIDENCE_DIR is required" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/scripts/oci-inspect.scm evidence \
		--instance-id '$(INSTANCE_ID)' --output-dir '$(EVIDENCE_DIR)'

oracle-build-generic:
	oracle/scripts/macos/build-generic-image.sh

oracle-upload-generic:
	@test -n "$(ORACLE_OBJECT_NAME)" || { echo "ORACLE_OBJECT_NAME is required" >&2; exit 2; }
	oracle/scripts/macos/upload-generic-image.sh

oracle-import-generic:
	@test -n "$(ORACLE_OBJECT_NAME)" || { echo "ORACLE_OBJECT_NAME is required" >&2; exit 2; }
	oracle/scripts/run-timed.sh image-import \
		oracle/scripts/macos/import-generic-image.sh

oracle-timings:
	oracle/scripts/timing-report.sh

oracle-stage0:
	@test -n "$(IMAGE_ID)" || { echo "IMAGE_ID is required" >&2; exit 2; }
	@test -n "$(SUBNET_ID)" || { echo "SUBNET_ID is required" >&2; exit 2; }
	oracle/scripts/run-timed.sh stage0-total \
		$(GUILE) --no-auto-compile -s oracle/scripts/05-verify-metadata-ssh.scm \
		--image-id '$(IMAGE_ID)' --subnet-id '$(SUBNET_ID)' $(YES)

SOURCE ?= .
COMMAND ?= ./run-tests.sh

oracle-stage1:
	@test -n "$(IMAGE_ID)" || { echo "IMAGE_ID is required" >&2; exit 2; }
	@test -n "$(SUBNET_ID)" || { echo "SUBNET_ID is required" >&2; exit 2; }
	oracle/scripts/run-timed.sh stage1-total \
	$(GUILE) --no-auto-compile -s oracle/scripts/validate.scm start \
		--image-id '$(IMAGE_ID)' --subnet-id '$(SUBNET_ID)' \
		--source '$(SOURCE)' --command '$(COMMAND)' $(KEEP) \
		$(if $(FORCE_DISCONNECT_AFTER),--force-disconnect-after '$(FORCE_DISCONNECT_AFTER)',) $(YES)

oracle-run-status oracle-logs oracle-collect oracle-stop oracle-cleanup oracle-handoff:
	@test -n "$(RUN_DIR)" || { echo "RUN_DIR is required" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/scripts/validation-lifecycle.scm \
		$(patsubst oracle-run-status,status,$(patsubst oracle-logs,logs,$(patsubst oracle-collect,collect,$(patsubst oracle-stop,stop,$(patsubst oracle-cleanup,cleanup,$(patsubst oracle-handoff,handoff,$@)))))) \
		--run-dir '$(RUN_DIR)' $(YES)

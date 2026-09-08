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

.PHONY: help dev-help test check manifest dev-test dev-check dev-manifest
.PHONY: wizard oracle-wizard download ssh oracle-download oracle-ssh personal-setup set-ip
.PHONY: gips-test gips-rust-test gips-check gips-daemon gips-status ipfs-docker
.PHONY: oracle-help oracle-test oracle-test-all
.PHONY: oracle-test-capacity oracle-test-image oracle-test-preferences
.PHONY: oracle-test-validation oracle-auth oracle-inventory
.PHONY: oracle-instance oracle-evidence oracle-stage0 oracle-stage1
.PHONY: oracle-run oracle-one-shot oracle-resume-check
.PHONY: oracle-run-status oracle-logs oracle-collect oracle-stop oracle-cleanup oracle-handoff
.PHONY: oracle-build-generic oracle-upload-generic oracle-import-generic oracle-timings
.PHONY: dev-oracle-test dev-oracle-test-all dev-oracle-run

help:
	@echo "Guix on Oracle - User targets:"
	@echo "  make wizard             Interactive step-by-step setup wizard"
	@echo "  make download           Download & verify published generic Guix image"
	@echo "  make ssh [IP=...] [AGENT=1] Connect to Guix instance (optional SSH agent forwarding)"
	@echo "  make personal-setup [IP=...] [AGENT=1] Run personal config setup on instance"
	@echo "  make set-ip IP=...      Update ORACLE_INSTANCE_IP in .env (or 'make set-ip IP=' to clear)"
	@echo ""
	@echo "Repository targets:"
	@echo "  make test               Run the complete local test suite"
	@echo "  make check              Run pre-deploy validation and the complete test suite"
	@echo "  make manifest           Regenerate SOURCE_MANIFEST.txt"
	@echo "  make gips-test          Run GIPS Guile Scheme test suite"
	@echo "  make gips-rust-test     Run GIPS Rust workspace test suite"
	@echo "  make gips-check         Run both Scheme and Rust GIPS test suites"
	@echo "  make gips-daemon        Start GIPS daemon (gipsd) locally"
	@echo "  make gips-status        Check GIPS daemon status and peer connectivity"
	@echo "  make ipfs-docker        Run Kubo IPFS daemon via Docker with swarm port 4001"
	@echo ""
	@echo "Developer targets:"
	@echo "  make dev-check          Run pre-deploy validation and test suite"
	@echo "  make dev-test           Run local test suite"
	@echo "  make dev-manifest       Regenerate SOURCE_MANIFEST.txt"
	@echo "  make dev-help           Show all developer & validation targets"

dev-help:
	@echo "Developer & validation targets:"
	@echo "  make dev-check            Run pre-deploy validation and test suite"
	@echo "  make dev-test             Run local test suite"
	@echo "  make dev-manifest         Regenerate SOURCE_MANIFEST.txt"
	@echo "  make dev-oracle-test      All offline Oracle test suites"
	@echo "  make dev-oracle-test-all  All four suites (requires Guix)"
	@echo "  make dev-oracle-run       Run disposable validation instance"
	@echo "  make oracle-help          Show full Oracle validation & lifecycle targets"

dev-test test:
	./run-tests.sh

dev-check check:
	lib/validate-before-deploy.sh --verbose
	./run-tests.sh

dev-manifest manifest:
	./update-manifest.sh

gips-test:
	$(GUILE) --no-auto-compile -s postinstall/recipes/add/gips.scm --self-test
	$(GUILE) --no-auto-compile -s postinstall/recipes/add/personal-sync.scm --self-test
	$(GUILE) --no-auto-compile -s postinstall/tests/test-personal-sync.scm
	$(GUILE) --no-auto-compile -s gips/test_api.scm
	$(GUILE) --no-auto-compile -s gips/test_sign.scm

gips-rust-test:
	@command -v cargo >/dev/null 2>&1 || { echo "cargo is required for Rust tests" >&2; exit 2; }
	cd gips && cargo test --workspace

gips-check: gips-test
	@if command -v cargo >/dev/null 2>&1; then \
		(cd gips && cargo test --workspace); \
	fi

gips-daemon:
	@command -v cargo >/dev/null 2>&1 || { echo "cargo is required to run gipsd" >&2; exit 2; }
	cd gips && cargo run -p gipsd

gips-status:
	@command -v cargo >/dev/null 2>&1 || { echo "cargo is required to run gips status" >&2; exit 2; }
	cd gips && cargo run -p gips -- status

ipfs-docker:
	@command -v docker >/dev/null 2>&1 || { echo "docker is required to run ipfs container" >&2; exit 2; }
	docker run -d --name ipfs \
		--restart unless-stopped \
		-v ipfs_staging:/export -v ipfs_data:/data/ipfs \
		-p 4001:4001 -p 4001:4001/udp -p 127.0.0.1:8080:8080 -p 127.0.0.1:5001:5001 \
		ipfs/kubo:latest
	@echo "[OK] IPFS (Kubo) container started. Swarm port 4001/tcp+udp and local API 5001 are active."

oracle-help:
	@echo "Read-only/local targets:"
	@echo "  make oracle-test          # all offline Oracle suites"
	@echo "  make oracle-test-all      # all four suites; requires Guix"
	@echo "  make oracle-test-capacity"
	@echo "  make oracle-test-image    # requires guix"
	@echo "  make oracle-test-preferences # requires Guix"
	@echo "  make oracle-test-validation"
	@echo "  make oracle-auth"
	@echo "  make oracle-inventory"
	@echo "  make oracle-timings       # historical median/p90 durations"
	@echo "  make oracle-instance      # defaults from .env"
	@echo "  make oracle-evidence      # defaults from .env"
	@echo ""
	@echo "Onboarding & access helpers:"
	@echo "  make wizard               # interactive step-by-step setup wizard"
	@echo "  make oracle-download      # download and verify published generic image"
	@echo "  make oracle-ssh IP=...    # connect to running instance with pre-flight check"
	@echo ""
	@echo "Disposable lifecycle targets (create an IN_TEST instance):"
	@echo "  make oracle-build-generic # local x86_64 QCOW2, resumable container"
	@echo "  make oracle-upload-generic # verified multipart upload; values from .env"
	@echo "  make oracle-import-generic # resumable custom-image import and waiter"
	@echo "  make oracle-stage0        # IMAGE_ID/SUBNET_ID default from .env"
	@echo "  make oracle-stage1 COMMAND='./run-tests.sh'"
	@echo "  make oracle-run IMAGE_ID=... SUBNET_ID=... SOURCE=. COMMAND='make check'"
	@echo "  make oracle-resume-check RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-run-status RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-logs RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-collect RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-stop RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-cleanup RUN_DIR=.oracle-validation/runs/..."
	@echo "  make oracle-handoff RUN_DIR=.oracle-validation/runs/..."
	@echo ""
	@echo "There is intentionally no generic destroy target."

oracle-test:
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-capacity.scm
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-validation.scm
	$(GUILE) --no-auto-compile -s oracle/tests/test-gips-cloud-validation.scm

oracle-test-all: oracle-test oracle-test-preferences oracle-test-image

oracle-test-capacity:
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-capacity.scm

oracle-test-image:
	@command -v guix >/dev/null 2>&1 || { echo "guix is required for the Oracle image evaluation suite" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-image.scm

oracle-test-preferences:
	@command -v guix >/dev/null 2>&1 || { echo "guix is required for the Oracle preferences suite" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/tests/test-oracle-preferences.scm

oracle-test-validation:
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

# Reusable non-secret defaults come from .env; command-line assignments still
# override them for a one-off run.
SOURCE ?= $(if $(ORACLE_SOURCE),$(ORACLE_SOURCE),.)
COMMAND ?= $(if $(ORACLE_COMMAND),$(ORACLE_COMMAND),./run-tests.sh)

oracle-stage1:
	@test -n "$(IMAGE_ID)" || { echo "IMAGE_ID is required" >&2; exit 2; }
	@test -n "$(SUBNET_ID)" || { echo "SUBNET_ID is required" >&2; exit 2; }
	oracle/scripts/run-timed.sh stage1-total \
	$(GUILE) --no-auto-compile -s oracle/scripts/validate.scm start \
		--image-id '$(IMAGE_ID)' --subnet-id '$(SUBNET_ID)' \
		--source '$(SOURCE)' --command '$(COMMAND)' $(KEEP) \
	$(if $(FORCE_DISCONNECT_AFTER),--force-disconnect-after '$(FORCE_DISCONNECT_AFTER)',) $(YES)

# Stable release-facing alias: all cloud inputs and the guest command remain
# explicit, while the underlying controller retains its bounded one-shot and
# ownership-gated cleanup behavior.
oracle-run oracle-one-shot:
	@test -n "$(IMAGE_ID)" || { echo "IMAGE_ID is required" >&2; exit 2; }
	@test -n "$(SUBNET_ID)" || { echo "SUBNET_ID is required" >&2; exit 2; }
	@test -n "$(SOURCE)" || { echo "SOURCE is required" >&2; exit 2; }
	@test -n "$(COMMAND)" || { echo "COMMAND is required" >&2; exit 2; }
	oracle/scripts/run-timed.sh oracle-one-shot \
	$(GUILE) --no-auto-compile -s oracle/scripts/validate.scm start \
		--image-id '$(IMAGE_ID)' --subnet-id '$(SUBNET_ID)' \
		--source '$(SOURCE)' --command '$(COMMAND)' $(KEEP) \
		$(if $(FORCE_DISCONNECT_AFTER),--force-disconnect-after '$(FORCE_DISCONNECT_AFTER)',) $(YES)

# Read-only reminder for a human/operator holding an exact checkpoint.  The
# actual continuation remains in the controller; this target never guesses or
# mutates OCI resources.
oracle-resume-check:
	@test -n "$(RUN_DIR)" || { echo "RUN_DIR is required" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/scripts/validation-lifecycle.scm \
		status --run-dir '$(RUN_DIR)' --json

oracle-run-status oracle-logs oracle-collect oracle-stop oracle-cleanup oracle-handoff:
	@test -n "$(RUN_DIR)" || { echo "RUN_DIR is required" >&2; exit 2; }
	$(GUILE) --no-auto-compile -s oracle/scripts/validation-lifecycle.scm \
		$(patsubst oracle-run-status,status,$(patsubst oracle-logs,logs,$(patsubst oracle-collect,collect,$(patsubst oracle-stop,stop,$(patsubst oracle-cleanup,cleanup,$(patsubst oracle-handoff,handoff,$@)))))) \
		--run-dir '$(RUN_DIR)' $(YES)

# Published image download & instance SSH helpers (Go)
OUTPUT ?= guix-oracle-generic.qcow2
IP ?= $(ORACLE_INSTANCE_IP)
KEY ?= $(ORACLE_SSH_KEY)

wizard oracle-wizard:
	go run ./cmd/oracle-wizard

download oracle-download:
	go run ./cmd/oracle-download -output "$(OUTPUT)" $(if $(FORCE),-force,)

AGENT_FLAG := $(if $(filter 1 true yes,$(AGENT)$(FORWARD_AGENT)$(ORACLE_FORWARD_AGENT)),-agent,)

ssh oracle-ssh:
	go run ./cmd/oracle-ssh $(if $(IP),-ip "$(IP)",) $(if $(INSTANCE_ID),-instance-id "$(INSTANCE_ID)",) $(if $(KEY),-key "$(KEY)",) $(AGENT_FLAG)

personal-setup:
	@test -n "$(IP)" || { echo "IP is required. Set ORACLE_INSTANCE_IP in .env or pass IP=... (e.g. make personal-setup IP=129.159.162.200)" >&2; exit 2; }
	go run ./cmd/oracle-ssh -ip "$(IP)" $(if $(KEY),-key "$(KEY)",) $(AGENT_FLAG) -t "bash -c 'wget -O ~/.personal-config.scm https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm && guile --no-auto-compile -s ~/.personal-config.scm'"

set-ip:
	@touch .env
	@if grep -qE '^#?[[:space:]]*(export[[:space:]]+)?ORACLE_INSTANCE_IP=' .env; then \
		awk -v new_ip="$(IP)" 'BEGIN{FS=OFS="="} $$1 ~ /^#?[[:space:]]*(export[[:space:]]+)?ORACLE_INSTANCE_IP$$/ { $$0="ORACLE_INSTANCE_IP=" new_ip } { print }' .env > .env.tmp && mv .env.tmp .env; \
	else \
		echo "ORACLE_INSTANCE_IP=$(IP)" >> .env; \
	fi
	@if [ -n "$(IP)" ]; then \
		echo "[OK] Updated ORACLE_INSTANCE_IP=$(IP) in .env"; \
	else \
		echo "[OK] Cleared ORACLE_INSTANCE_IP in .env"; \
	fi

# Developer aliases
dev-oracle-test: oracle-test
dev-oracle-test-all: oracle-test-all
dev-oracle-run: oracle-run

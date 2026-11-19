SHELL := /bin/bash

TF := ./terraform-with-secrets.sh
PWSH := pwsh -NoProfile -File scripts/Test-PowerShell.ps1

.PHONY: help init validate fmt-check tf-validate shellcheck ps-lint tflint tfsec git-diff-check plan apply destroy status run-commands password ip

help:
	@printf '%s\n' \
		'make validate      Run fmt, validate, shellcheck, PowerShell lint, tflint, tfsec, and diff checks' \
		'make plan          Run terraform plan through the secret-loading wrapper' \
		'make apply         Apply after explicit confirmation: make apply CONFIRM=apply' \
		'make destroy       Destroy after explicit confirmation: make destroy CONFIRM=destroy' \
		'make status        Show Azure VM power/provisioning state' \
		'make run-commands  Show each Azure VM run command status and output' \
		'make password      Print the sensitive VM admin password' \
		'make ip            Print the VM public IP'

init:
	terraform init -backend=false -input=false

fmt-check:
	terraform fmt -check -recursive

tf-validate:
	terraform validate

shellcheck:
	shellcheck terraform-with-secrets.sh scripts/hyperv-prep-harness.sh

ps-lint:
	$(PWSH)

tflint:
	tflint --init
	tflint --format compact

tfsec:
	tfsec . --no-color

git-diff-check:
	git diff --check

validate: init fmt-check tf-validate shellcheck ps-lint tflint tfsec git-diff-check

plan:
	$(TF) plan -no-color

apply:
	@test "$(CONFIRM)" = "apply" || { echo 'Refusing to apply. Re-run with: make apply CONFIRM=apply'; exit 1; }
	$(TF) apply

destroy:
	@test "$(CONFIRM)" = "destroy" || { echo 'Refusing to destroy. Re-run with: make destroy CONFIRM=destroy'; exit 1; }
	$(TF) destroy

status:
	@rg=$$($(TF) output -raw resource_group_name) && \
	vm=$$($(TF) output -raw vm_name) && \
	az vm show -d --resource-group "$$rg" --name "$$vm" -o table

run-commands:
	@rg=$$($(TF) output -raw resource_group_name) && \
	vm=$$($(TF) output -raw vm_name) && \
	for cmd in enable-remote-management install-hyperv install-podman prepare-podman-hyperv create-runner-user configure-podman-machine create-podman-startup-task install-github-runner verify-runner; do \
		echo "=== $$cmd ==="; \
		az vm run-command show \
			--resource-group "$$rg" \
			--vm-name "$$vm" \
			--run-command-name "$$cmd" \
			--instance-view \
			--query '{name:name,code:instanceView.executionState,output:instanceView.output}' \
			-o json || true; \
	done

password:
	@$(TF) output -raw vm_admin_password

ip:
	@$(TF) output -raw vm_public_ip

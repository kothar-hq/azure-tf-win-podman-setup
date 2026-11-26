# -------------------------------
# Terraform & providers
# -------------------------------
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "azurerm" {
  features {}
}

# -------------------------------
# Variables
# -------------------------------
variable "resource_group_name" {
  type    = string
  default = "tf-demo-rg"
}
variable "location" {
  type    = string
  default = "East US"
}
variable "vm_admin_username" {
  type    = string
  default = "azureuser"
}
variable "vm_name" {
  type        = string
  description = "Name of the Windows VM and the GitHub Actions runner."
  default     = "w-pdm-hpv-vm"
}
variable "vm_size" {
  type        = string
  description = "Azure VM size. Must support nested virtualization and be large enough for the Podman machine."
  default     = "Standard_D4s_v3"
}
variable "github_repository" {
  type        = string
  description = "GitHub repository (owner/name) that the runner registers with."
  default     = "kothar-hq/host-container-capabilities"
}
variable "github_token" {
  type        = string
  description = "GitHub token that can create runner registration tokens for the repository."
  sensitive   = true
}
variable "runner_group" {
  type        = string
  description = "GitHub Actions runner group."
  default     = "Default"
}
variable "runner_labels" {
  type        = string
  description = "Labels advertised by the runner, including Windows and Podman capabilities."
  default     = "self-hosted,Windows,WindowsServer2025,podman,windows-podman"
}
variable "runner_user" {
  type        = string
  description = "Local Windows account that runs the GitHub Actions runner and Podman."
  default     = "podmanrunner"
}
variable "runner_install_root" {
  type        = string
  description = "Directory where the GitHub Actions runner is installed."
  default     = "C:\\actions-runner"
}
variable "podman_machine_name" {
  type    = string
  default = "podman-machine-default"
}
variable "podman_cpus" {
  type    = number
  default = 4
}
variable "podman_memory_mb" {
  type    = number
  default = 8192
}
variable "podman_disk_gb" {
  type    = number
  default = 80
}
variable "enable_remote_management" {
  description = "Open SSH/SCP and PowerShell Remoting (WinRM) from the current public IP and enable those services on the VM. RDP remains available."
  type        = bool
  default     = true
}
variable "podman_version" {
  type        = string
  description = "Podman release to install from GitHub, without the leading v (for example 6.2.0), or \"latest\". Ignored when podman_msi_path is set."
  default     = "latest"

  validation {
    condition     = var.podman_version == "latest" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.podman_version))
    error_message = "podman_version must be \"latest\" or a version such as 6.2.0."
  }
}
variable "runner_version" {
  type        = string
  description = "GitHub Actions runner release to install, without the leading v (for example 2.329.0), or \"latest\"."
  default     = "latest"

  validation {
    condition     = var.runner_version == "latest" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.runner_version))
    error_message = "runner_version must be \"latest\" or a version such as 2.329.0."
  }
}
variable "podman_msi_path" {
  type        = string
  description = "Path to a local Podman MSI (for example ./podman-6.3.0.msi). When set, Terraform uploads it to a private storage account and the VM installs it instead of a GitHub release."
  default     = null

  validation {
    condition     = var.podman_msi_path == null || can(regex("\\.msi$", var.podman_msi_path))
    error_message = "podman_msi_path must point to a .msi file."
  }
}
variable "vm_spot" {
  type        = bool
  description = "Use Azure Spot pricing (pre-emptible VM). Spot VMs cost 70-90% less but can be evicted by Azure; eviction policy is Deallocate so state is preserved. Set false for a regular on-demand VM."
  default     = true
}

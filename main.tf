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
  default = "tf-demo-rg"
}
variable "location" {
  default = "East US"
}
variable "vm_admin_username" {
  default = "azureuser"
}
variable "vm_name" {
  description = "Name of the Windows VM and the GitHub Actions runner."
  default     = "w-pdm-hpv-vm"
}
variable "vm_size" {
  description = "Azure VM size. Must support nested virtualization and be large enough for the Podman machine."
  default     = "Standard_D4s_v3"
}
variable "github_repository" {
  description = "GitHub repository (owner/name) that the runner registers with."
  default     = "kothar-hq/host-container-capabilities"
}
variable "github_token" {
  description = "GitHub token that can create runner registration tokens for the repository."
  sensitive   = true
}
variable "runner_group" {
  description = "GitHub Actions runner group."
  default     = "Default"
}
variable "runner_labels" {
  description = "Labels advertised by the runner, including Windows and Podman capabilities."
  default     = "self-hosted,Windows,WindowsServer2025,podman,windows-podman"
}
variable "runner_user" {
  description = "Local Windows account that runs the GitHub Actions runner and Podman."
  default     = "podmanrunner"
}
variable "runner_install_root" {
  description = "Directory where the GitHub Actions runner is installed."
  default     = "C:\\actions-runner"
}
variable "podman_machine_name" {
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

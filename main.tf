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
  }
}

provider "azurerm" {
  features {}
}

# -------------------------------
# Current public IP
# -------------------------------
data "http" "my_ip" {
  url = "https://api.ipify.org?format=text"
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"
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
  default     = "podman-vm"
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

# -------------------------------
# Generated credentials
# -------------------------------
resource "random_password" "vm_admin_password" {
  length           = 24
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_=+?"
}

resource "random_password" "runner_password" {
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_=+?"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# -------------------------------
# Resource Group
# -------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# -------------------------------
# Storage Account
# -------------------------------
resource "azurerm_storage_account" "storage" {
  name                     = "tfstorage${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Bootstrap files are served to the VM extension from this private container.
resource "azurerm_storage_container" "runner_bootstrap" {
  name                  = "runner-bootstrap"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "setup_script" {
  name                   = "Setup-WindowsPodmanActionRunner.ps1"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.runner_bootstrap.name
  type                   = "Block"
  content_type           = "text/plain; charset=utf-8"
  source_content         = file("${path.module}/Setup-WindowsPodmanActionRunner.ps1")
}

resource "azurerm_storage_blob" "wrapper_script" {
  name                   = "New-WindowsPodmanActionRunner.ps1"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.runner_bootstrap.name
  type                   = "Block"
  content_type           = "text/plain; charset=utf-8"
  source_content         = file("${path.module}/New-WindowsPodmanActionRunner.ps1")
}

resource "azurerm_storage_blob" "runner_config" {
  name                   = "runner-config.json"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.runner_bootstrap.name
  type                   = "Block"
  content_type           = "application/json"
  source_content = jsonencode({
    github_repository = var.github_repository
    github_token      = var.github_token
    runner_name       = var.vm_name
    runner_labels     = var.runner_labels
    runner_group      = var.runner_group
    runner_password   = random_password.runner_password.result
  })
}

# -------------------------------
# Virtual Network & Subnet
# -------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "tf-demo-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "tf-demo-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# -------------------------------
# Network Security Group - RDP from current public IP only
# -------------------------------
resource "azurerm_network_security_group" "rdp" {
  name                = "tf-demo-rdp-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-RDP-From-MyIP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = local.my_ip_cidr
    destination_address_prefix = "*"
  }
}

# -------------------------------
# Public IP & NIC
# -------------------------------
resource "azurerm_public_ip" "pip" {
  name                = "tf-demo-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "nic" {
  name                = "tf-demo-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "nic" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.rdp.id
}

# -------------------------------
# Virtual Machine
# -------------------------------
resource "azurerm_windows_virtual_machine" "vm" {
  name                  = var.vm_name
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_D2s_v3" # Smallest nested virtualization SKU
  admin_username        = var.vm_admin_username
  admin_password        = random_password.vm_admin_password.result
  network_interface_ids = [azurerm_network_interface.nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-Datacenter"
    version   = "latest"
  }
}

# -------------------------------
# VM Extension - Run Runner Bootstrap
# -------------------------------
resource "azurerm_virtual_machine_extension" "custom_script" {
  name                 = "run-custom-script"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      azurerm_storage_blob.setup_script.url,
      azurerm_storage_blob.wrapper_script.url,
      azurerm_storage_blob.runner_config.url,
    ]
  })

  protected_settings = jsonencode({
    storageAccountName = azurerm_storage_account.storage.name
    storageAccountKey  = azurerm_storage_account.storage.primary_access_key
    commandToExecute   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\New-WindowsPodmanActionRunner.ps1 -ConfigPath .\\runner-config.json"
  })
}

# -------------------------------
# Outputs
# -------------------------------
output "vm_admin_password" {
  description = "Randomly generated administrator password for the Windows VM."
  value       = random_password.vm_admin_password.result
  sensitive   = true
}

output "vm_public_ip" {
  description = "Public IP address assigned to the Windows VM."
  value       = azurerm_public_ip.pip.ip_address
}

# -------------------------------
# Base VM: networking, credentials, and the virtual machine
# -------------------------------

# -------------------------------
# Current public IP (for RDP access)
# -------------------------------
data "http" "my_ip" {
  url = "https://api.ipify.org?format=text"
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"

  remote_management_rules = var.enable_remote_management ? {
    ssh = {
      name     = "Allow-SSH-From-MyIP"
      priority = 110
      port     = "22"
    }
    winrm = {
      name     = "Allow-WinRM-From-MyIP"
      priority = 120
      port     = "5985"
    }
  } : {}
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

# -------------------------------
# Resource Group
# -------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
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
# Network Security Group - management access from current public IP only
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

  dynamic "security_rule" {
    for_each = local.remote_management_rules

    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = local.my_ip_cidr
      destination_address_prefix = "*"
    }
  }
}

# -------------------------------
# Public IP & NIC
# -------------------------------
resource "azurerm_public_ip" "pip" {
  name                = "tf-demo-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  # Basic SKU public IPs are retired. Static allocation also means the address
  # is known before the VM boots, which the post-reboot TCP probe relies on.
  sku               = "Standard"
  allocation_method = "Static"
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
  name                              = var.vm_name
  resource_group_name               = azurerm_resource_group.rg.name
  location                          = azurerm_resource_group.rg.location
  size                              = var.vm_size
  admin_username                    = var.vm_admin_username
  admin_password                    = random_password.vm_admin_password.result
  network_interface_ids             = [azurerm_network_interface.nic.id]
  provision_vm_agent                = true
  vm_agent_platform_updates_enabled = true

  boot_diagnostics {}

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

output "resource_group_name" {
  description = "Resource group containing the Windows VM."
  value       = azurerm_resource_group.rg.name
}

output "vm_name" {
  description = "Name of the Windows VM."
  value       = azurerm_windows_virtual_machine.vm.name
}

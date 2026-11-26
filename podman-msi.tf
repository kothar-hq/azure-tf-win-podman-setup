# -------------------------------
# Optional local Podman MSI: when var.podman_msi_path is set, upload it to a
# private storage account and have install-podman download it with a
# short-lived read-only SAS instead of a GitHub release.
# -------------------------------
resource "random_string" "podman_msi_storage" {
  count   = local.use_local_podman_msi ? 1 : 0
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "podman_msi" {
  count                           = local.use_local_podman_msi ? 1 : 0
  name                            = "podmanmsi${random_string.podman_msi_storage[0].result}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Terraform uploads from the current public IP; the VM reaches the account
  # through the subnet's Microsoft.Storage service endpoint (IP rules do not
  # apply to traffic from VMs in the same region).
  network_rules {
    default_action             = "Deny"
    ip_rules                   = [trimspace(data.http.my_ip.response_body)]
    virtual_network_subnet_ids = [azurerm_subnet.subnet.id]
    bypass                     = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "podman_msi" {
  count                 = local.use_local_podman_msi ? 1 : 0
  name                  = "podman"
  storage_account_name  = azurerm_storage_account.podman_msi[0].name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "podman_msi" {
  count                  = local.use_local_podman_msi ? 1 : 0
  name                   = basename(var.podman_msi_path)
  storage_account_name   = azurerm_storage_account.podman_msi[0].name
  storage_container_name = azurerm_storage_container.podman_msi[0].name
  type                   = "Block"
  source                 = var.podman_msi_path
  content_md5            = filemd5(var.podman_msi_path)
  content_type           = "application/x-msi"
}

# A fixed start time keeps the SAS (and so the install-podman parameters)
# stable between plans, so the run command is not re-run on every apply.
resource "time_static" "podman_msi_sas" {
  count = local.use_local_podman_msi ? 1 : 0
}

data "azurerm_storage_account_blob_container_sas" "podman_msi" {
  count             = local.use_local_podman_msi ? 1 : 0
  connection_string = azurerm_storage_account.podman_msi[0].primary_connection_string
  container_name    = azurerm_storage_container.podman_msi[0].name
  https_only        = true
  start             = time_static.podman_msi_sas[0].rfc3339
  expiry            = timeadd(time_static.podman_msi_sas[0].rfc3339, "24h")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

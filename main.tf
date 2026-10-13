
data "azurerm_client_config" "current" {}

resource "azurerm_storage_container" "bkp_container" {
  # checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"
  name                  = "backup-container"
  storage_account_id    = var.aks_backup_storage_account_id
  container_access_type = "private"
}

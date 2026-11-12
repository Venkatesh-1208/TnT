Step 1: Prevent Identity Replacement in the Shared Module Repo
In your shared module repository (terraform-azurerm-wps-kubernetes):
1.	Open main.tf and change the AKS identity name back to id- (or allow a variable fallback):
hcl
# main.tf line 12
resource "azurerm_user_assigned_identity" "aks_user_assigned_identity" {
  resource_group_name = var.resource_group_name == null ? azurerm_resource_group.aks_resources[0].name : var.resource_group_name
  location            = var.location
  name                = "id-${var.fullname}-001"   # Keep "id-" to prevent cluster identity recreation
  tags = local.tags
}
2.	Open locals.tf and change the AppGW identity name back to id-:
hcl
# locals.tf line 4
locals {
  appgw_name                  = "appgw-${var.fullname}-001"
  appgw_name_fqdn             = "appgw-${var.fullname}-001.${var.appgw_dns_zone_name}"
  appgw_managed_identity_name = "id-${local.appgw_name}"   # Keep "id-" to prevent AppGW identity recreation
  ...
3.	Commit and push this change to your module repository, or update the tag v6.8.4 (or tag as v6.8.5 and update ref=v6.8.5 in the workload repo).
Impact: This single step eliminates 8 out of the 11 destroys. Both identities, the AKS cluster identity binding, the AppGW identity binding, and all 6 role assignments remain completely untouched and in-place.
________________________________________

Step 2: Clean up the Workload Repo (mytennet-acc1-workload)
1.	Open terraform/main.tf: Remove lines 1–4:
hcl
# REMOVE THESE LINES (they cause Key Vault not found errors):
data "azurerm_key_vault" "kv" {
  name                = "kv-${local.aks.fullname}-001"
  resource_group_name = azurerm_resource_group.aks_resources.name
}
Reason: This data source is unneeded because module.aks.key_vault is already functioning in your remote plan. Furthermore, kv-${local.aks.fullname}-001 does not exist in Azure.
2.	Verify that config/config.yml retains the external storage account input:
yaml
aks_backup_storage_account_id: "/subscriptions/5bdb1978-288f-494e-8bb1-b32f51e2fad1/resourceGroups/rg-nl-cf-myte1-acc-euw-yjjlh-001/providers/Microsoft.Storage/storageAccounts/stacfnlmyte1acceuwyjjlh001"
3.	Commit and push your changes to your Azure DevOps workload repository.

________________________________________
  
Step 3:Alternative: Place it in the Shared Module Repo
4.	If you prefer to fix it centrally in the module so every workload benefits from it, you can place this inside terraform-azurerm-wps-kubernetes/modules/backup/removed.tf:
5.	hcl
6.	# modules/backup/removed.tf (inside the shared module)
7.	removed {
8.	  from = azurerm_storage_account.bkp_sa
9.	  lifecycle {
10.	    destroy = false
11.	  }
12.	}
13.	removed {
14.	  from = azurerm_private_endpoint.bkp_private_endpoint
15.	  lifecycle {
16.	    destroy = false
17.	  }
18.	}
19.	removed {
20.	  from = time_sleep.wait_for_backupinstance
21.	  lifecycle {
22.	    destroy = false
23.	  }
24.	}
25.	(Putting it in the workload repo as mytennet-acc1-workload/terraform/removed.tf is usually faster as you do not need to release a new module version).


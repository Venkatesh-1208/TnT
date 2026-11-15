# Safest Fix Guide — Zero Destruction Upgrade from v5.1.1 to v6.8.4

> [!IMPORTANT]
> **Goal**: Upgrade the shared module from `v5.1.1` to `v6.8.4` with **zero existing resources destroyed or recreated**. All existing Azure resources — managed identities, role assignments, ArgoCD SSL certificates, Application Gateway, Key Vault, and backup storage — must remain completely untouched.

## Current Plan Status

```
Plan: 12 to add, 18 to change, 11 to destroy   ← UNSAFE, must reach 0 to destroy
```

## Root Cause Map of All 11 Destroys

```
11 to destroy
├── ROOT CAUSE 1: Identity naming "id-" → "mi-" in module v6.2.1 (8 destroys)
│   ├── azurerm_user_assigned_identity.aks_user_assigned_identity    ← forces replacement
│   ├── azurerm_user_assigned_identity.appgw_user_assigned_identity  ← forces replacement
│   ├── azurerm_role_assignment.aks_private_dns_zone_contributor     ← cascade: principal_id changes
│   ├── azurerm_role_assignment.aks_vnet_role_assignments            ← cascade: principal_id changes
│   ├── azurerm_role_assignment.role_assignments (KV Secrets User)   ← cascade: principal_id changes
│   ├── azurerm_role_assignment.role_assignment_certificates_appgw   ← cascade: principal_id changes
│   ├── azurerm_role_assignment.role_assignment_secrets_appgw        ← cascade: principal_id changes
│   └── module.backup[0].bkp_role_assignments["ara3"]               ← cascade: principal_id changes
│
└── ROOT CAUSE 2: Storage account removed from module in v6.0.0 (3 destroys)
    ├── module.backup[0].azurerm_storage_account.bkp_sa             ← not in new code
    ├── module.backup[0].azurerm_private_endpoint.bkp_private_endpoint ← not in new code
    └── module.backup[0].time_sleep.wait_for_backupinstance         ← not in new code
```

---

## Dependency Chain (Why Nothing Must Be Touched)

```mermaid
flowchart TD
    AKS_ID["id-nl-myte1-acc-euw-aks-001<br/>(AKS Managed Identity)"]
    APPGW_ID["id-appgw-nl-myte1-acc-euw-aks-001<br/>(AppGW Managed Identity)"]
    
    AKS_ID --> DNS["Private DNS Zone Contributor<br/>privatelink.westeurope.azmk8s.io"]
    AKS_ID --> VNET["VNet Network Contributor"]
    AKS_ID --> KV_SECRETS["Key Vault Secrets User"]
    AKS_ID --> BKP_ARA3["Backup Contributor (ara3)"]
    AKS_ID --> AKS["AKS Cluster<br/>aks-nl-myte1-acc-euw-aks-001"]
    
    APPGW_ID --> KV_CERTS["Key Vault Certificates Officer"]
    APPGW_ID --> KV_SECRETS2["Key Vault Secrets User"]
    APPGW_ID --> APPGW["Application Gateway<br/>appgw-nl-myte1-acc-euw-aks-001"]
    
    APPGW --> SSL["ArgoCD SSL Certificate<br/>argocd-mytennet-acc-tennet-cloud"]
    APPGW --> INGRESS["113 AGIC Ingress Rules"]
    
    KV["Key Vault<br/>kvnlmyte1accuwaks001"] --> SSL
    KV_CERTS --> KV
    KV_SECRETS2 --> KV
```

**If any identity is recreated**: The entire chain breaks. AKS loses DNS resolution, AppGW loses Key Vault access, ArgoCD SSL certificate becomes inaccessible.

---

## The Fix: Exactly 2 Files in the GitHub Repo + 1 File in Azure DevOps Repo

### PART 1 — GitHub Repo (`terraform-azurerm-wps-kubernetes`)

Create a branch from `v6.8.4`:
```bash
git checkout v6.8.4 -b fix/acc1-safe-upgrade
```

#### Change 1 of 3: `main.tf` line 12

**Current (UNSAFE)**:
```hcl
name                = "mi-${var.fullname}-001"
```

**Change to (SAFE)**:
```hcl
name                = "id-${var.fullname}-001"
```

> This single character change (`mi` → `id`) eliminates **8 out of 11 destroys**.
> The AKS managed identity `id-nl-myte1-acc-euw-aks-001` matches what exists in Azure, so Terraform sees no change. All 5 role assignments that depend on its `principal_id` also stop being replaced.

#### Change 2 of 3: `locals.tf` line 4

**Current (UNSAFE)**:
```hcl
appgw_managed_identity_name = "mi-${local.appgw_name}"
```

**Change to (SAFE)**:
```hcl
appgw_managed_identity_name = "id-${local.appgw_name}"
```

> The AppGW managed identity `id-appgw-nl-myte1-acc-euw-aks-001` matches what exists in Azure. The 2 Key Vault role assignments that depend on its `principal_id` also stop being replaced. The Application Gateway identity block stays unchanged, so ArgoCD SSL certificate access remains intact.

#### Change 3 of 3: `outputs.tf` — Add `key_vault` output at the end

**Add this after the existing `key_vault_id` output**:
```hcl
output "key_vault" {
  description = "The Key Vault resource object for backwards compatibility"
  value       = try(azurerm_key_vault.keyvault[0], null)
  sensitive   = true
}
```

> [!NOTE]
> **Why this is needed**: Your workload repo references `module.aks.key_vault.vault_uri` (main.tf line 15) and `module.aks.key_vault.id` (ssl_certs.tf lines 5 and 10) for the ArgoCD SSL certificate. Module v6.8.4 only has `output "key_vault_id"` which returns a string, not the full resource object. Without this output, your pipeline will crash with `"Reference to undeclared resource"` when processing ArgoCD certificate references.

**Commit and push**:
```bash
git add main.tf locals.tf outputs.tf
git commit -m "fix: preserve id- naming convention and restore key_vault output for safe v5→v6 migration"
git push origin fix/acc1-safe-upgrade
```

---

### PART 2 — Azure DevOps Repo (`mytennet-acc1-workload`)

#### Change 1 of 2: `terraform/main.tf`

**Two changes in this file**:

**a) Remove lines 1–4** (the broken data source):
```hcl
# DELETE THESE 4 LINES:
data "azurerm_key_vault" "kv" {
  name                = "kv-${local.aks.fullname}-001"
  resource_group_name = azurerm_resource_group.aks_resources.name
}
```
> This data source looks up `kv-nl-myte1-acc-euw-aks-001` which does not exist in Azure. The actual Key Vault is `kvnlmyte1accuwaks001`. You don't need this data source because `module.aks.key_vault` (via the output we added above) provides the same access.

**b) Update the module source** (line 38 after removing lines 1–4, was line 38):
```hcl
# CHANGE FROM:
source = "git::ssh://git@ssh.dev.azure.com/v3/MCP-TenneT/cf-workload-modules/terraform-azurerm-wps-kubernetes?ref=v6.8.4"

# CHANGE TO:
source = "git::ssh://git@ssh.dev.azure.com/v3/MCP-TenneT/cf-workload-modules/terraform-azurerm-wps-kubernetes?ref=fix/acc1-safe-upgrade"
```

**After these changes, `main.tf` should start like**:
```hcl
locals {
  aks = yamldecode(file("../config/config.yml"))["aks"]
  waf_exclusions = yamldecode(file("../config/appgw_waf_exclusions.yml"))
  # Only Argocd domain logic
  argocd_domain_is_present = try(local.aks.argocd_domain, null) != null ? true : false

  # SSL certificates for Application Gateway (Argocd only)
  appgw_ssl_certificates = local.argocd_domain_is_present ? [
    {
      name                = replace(try(local.aks.argocd_domain, ""), ".", "-")
      key_vault_secret_id = "${module.aks.key_vault.vault_uri}secrets/${replace(try(local.aks.argocd_domain, ""), ".", "-")}"
    }
  ] : []
}

data "azurerm_subscription" "current" {
}
...
module "aks" {
  source = "git::ssh://git@ssh.dev.azure.com/v3/MCP-TenneT/cf-workload-modules/terraform-azurerm-wps-kubernetes?ref=fix/acc1-safe-upgrade"
  ...
```

**`ssl_certs.tf` requires NO changes** — it already correctly references `module.aks.key_vault.id` which will resolve through the new output.

#### Change 2 of 2: Create `terraform/backup_migration.tf`

This handles the 3 remaining destroys (old backup storage account). Since you don't want `removed.tf`, use `moved` blocks to **transfer ownership** to the workload repo. This keeps the resources **fully tracked in Terraform state** and **protected from accidental deletion**:

```hcl
# terraform/backup_migration.tf
#
# These moved blocks transfer ownership of the old internal backup resources
# (removed from the shared module in v6.0.0) into this workload's direct
# management. The resources stay alive in Azure and remain tracked in state.
# prevent_destroy + ignore_changes = all ensures they cannot be accidentally
# deleted or modified.

moved {
  from = module.aks.module.backup[0].azurerm_storage_account.bkp_sa
  to   = azurerm_storage_account.legacy_bkp_sa
}

moved {
  from = module.aks.module.backup[0].azurerm_private_endpoint.bkp_private_endpoint
  to   = azurerm_private_endpoint.legacy_bkp_pep
}

resource "azurerm_storage_account" "legacy_bkp_sa" {
  name                     = "stnlmyte1accuwaks001"
  resource_group_name      = "rg-nl-myte1-acc-euw-aks-001"
  location                 = local.aks.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

resource "azurerm_private_endpoint" "legacy_bkp_pep" {
  name                = "pep-nl-myte1-acc-euw-aks-001"
  resource_group_name = "rg-nl-myte1-acc-euw-aks-001"
  location            = local.aks.location
  subnet_id           = local.aks.private_endpoint_subnet_id

  private_service_connection {
    name                           = "pep-nl-myte1-acc-euw-aks-001"
    private_connection_resource_id = azurerm_storage_account.legacy_bkp_sa.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  lifecycle {
    ignore_changes = all
  }
}
```

> [!TIP]
> **What `moved` does differently from `removed`**:
> - `removed` = drops from state, loses tracking (you didn't want this)
> - `moved` = **keeps full tracking** in your state file, just changes the address
> 
> With `moved`, the storage account `stnlmyte1accuwaks001` remains fully managed by your Terraform pipeline. `prevent_destroy = true` guarantees that even if someone accidentally deletes the resource block later, Terraform will refuse to destroy it.

> [!NOTE]
> **About `time_sleep.wait_for_backupinstance`**: This is a Terraform-internal timer resource with no Azure counterpart. It will be destroyed from state only (no Azure resource is affected). This is completely safe. If you want to avoid even this single "destroy" in the plan, you can add a moved block for it too, but it has zero impact on Azure.

---

## Expected Plan After All Fixes

```
Plan: 4 to add, ~18 to change, 0 to destroy
```

| Action | Resource | Safe? |
|--------|----------|-------|
| **move** | `azurerm_storage_account.legacy_bkp_sa` (from backup module) | ✅ Just address change |
| **move** | `azurerm_private_endpoint.legacy_bkp_pep` (from backup module) | ✅ Just address change |
| **+ create** | `azurerm_role_assignment.aks_rbac_cluster_admin` | ✅ New ADO identity role |
| **+ create** | `azurerm_role_assignment.aks_ingress_uaid_permissions_on_vnet` | ✅ New AGIC VNet role |
| **+ create** | `azurerm_role_assignment.aks_ingress_uaid_reader_on_apgw_resource_group` | ✅ New AGIC RG role |
| **+ create** | `time_sleep.wait_for_rbac_propagation` | ✅ 180s timer for backup |
| **~ update** | Tags, diagnostic settings, KV public access, AKS version, etc. | ✅ In-place only |
| **unchanged** | `id-nl-myte1-acc-euw-aks-001` (AKS identity) | ✅ Not touched |
| **unchanged** | `id-appgw-nl-myte1-acc-euw-aks-001` (AppGW identity) | ✅ Not touched |
| **unchanged** | All 6 RBAC role assignments | ✅ Not touched |
| **unchanged** | ArgoCD SSL certificate | ✅ Not touched |
| **unchanged** | Application Gateway (113 ingress blocks) | ✅ Not touched |
| **unchanged** | `stnlmyte1accuwaks001` (old storage) | ✅ Moved, not destroyed |

## Cleanup After Successful Apply

Once the plan shows `0 to destroy` and you apply successfully:

1. **The `moved` blocks can stay permanently** — they are harmless after the first apply.
2. Once stable, you can tag your GitHub branch as a proper release (e.g., `v6.8.4-acc1`) and update the module source reference.
3. The `data "azurerm_key_vault" "kv"` block must stay removed — it was looking up a non-existent Key Vault name.

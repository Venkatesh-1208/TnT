# Generic variables for the AKS module
variable "fullname" {
  type        = string
  description = "Fullname for the resources."
}

variable "shortname" {
  type        = string
  description = "Shortname for teh resources."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group, to use if not using the default."
  default     = null
}

variable "location" {
  description = "Location to provision resources in."
  type        = string
  default     = "westeurope"
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "The id of the subnet for the private endpoints."
}

variable "key_vault_id" {
  type        = string
  description = "The id of the key vault."
  default     = null
}

variable "group_names" {
  description = "name of different groups created in this module"
  type = object({
    AzureKubernetesServiceRBACAdmin        = optional(string)
    AzureKubernetesServiceRBACClusterAdmin = optional(string)
    AzureKubernetesServiceRBACReader       = optional(string)
    AzureKubernetesServiceRBACWriter       = optional(string)
  })
  default = {
    AzureKubernetesServiceRBACAdmin        = null
    AzureKubernetesServiceRBACClusterAdmin = null
    AzureKubernetesServiceRBACReader       = null
    AzureKubernetesServiceRBACWriter       = null
  }
}

variable "mandatory_tags" {
  description = "mandatory_tags"
  type        = any
}

variable "optional_tags" {
  description = "optional_tags"
  type = object({
    IaaSBackupSchedule   = optional(string)
    IaaSPowerOffSchedule = optional(string)
    IaaSPowerOnSchedule  = optional(string)
    IaaSUpdateSchedule   = optional(string)
    SandboxEndDate       = optional(string)
    Entity               = optional(string)
  })
  default = null
}

variable "pim_enabled" {
  description = "Add PIM roles"
  type        = bool
  default     = true
}

variable "pim_policy" {
  description = "Parameters for the PIM policy"
  type = object({
    duration_days = number
    active_assignment_rules = optional(object({
      expire_after = string
    }))
    eligible_assignment_rules = optional(object({
      expiration_required = bool
    }))
    activation_rules = optional(object({
      approval_stage = optional(object({
        primary_approver = optional(object({
          type = string
        }))
      }))
      maximum_duration      = string
      require_approval      = bool
      require_justification = bool
    }))
  })
  default = {
    duration_days = 365
    active_assignment_rules = {
      expire_after = "P365D"
    }
    eligible_assignment_rules = {
      expiration_required = false
    }
    activation_rules = {
      approval_stage = {
        primary_approver = {
          type = "Group"
        }
      }
      maximum_duration      = "PT8H"
      require_approval      = true
      require_justification = true
    }
  }
}

variable "domain_name_label" {
  description = "Label for the Domain Name on the public IP. Used to make up the FQDN."
  type        = string
  default     = null
}

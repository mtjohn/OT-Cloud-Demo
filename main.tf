# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = ">= 2.26"
    }
    helm = {
      source = "hashicorp/helm"
      version = "1.2.2"
    }
    azuread = {
      source = "hashicorp/azuread"
      version = "1.1.1"
    }
  }
}

provider "azurerm" {
  features {}
}

# Set default name prefix
variable "name_prefix" {
  default = "k8s-cluster"
}

# Set default location
variable "location" {
  default = "australiaeast"
}

# Create Resource Group
resource "azurerm_resource_group" "aks" {
  name     = "${var.name_prefix}-rg"
  location = var.location
}

# Create Azure AD Application for Service Principal
resource "azuread_application" "aks" {
  name = "${var.name_prefix}-sp"
}

# Create Service Principal
resource "azuread_service_principal" "aks" {
  application_id = azuread_application.aks.application_id
}

# Generate random string to be used for Service Principal Password
resource "random_string" "password" {
  length  = 32
  special = true
}

# Create Service Principal password
resource "azuread_service_principal_password" "aks" {
  end_date             = "2299-12-30T23:00:00Z"                        # Forever
  service_principal_id = azuread_service_principal.aks.id
  value                = random_string.password.result
}

# Create Azure Kubernetes Cluster
# - Resource details lifted from basic example on https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster
# - Changed vm_size from "Standard_D2_v2" as this is deemed a Production size VM, o changed to use the smallest A-Series v2 vm's "Best suited for entry level workloads (development or test)""
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.name_prefix}-aks"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = var.name_prefix

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "standard_a2_v2"
  }

  service_principal {
    client_id     = azuread_application.aks.application_id
    client_secret = azuread_service_principal_password.aks.value
  }
}

provider "helm" {
  kubernetes {
    host                    = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_key              = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    client_certificate      = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    cluster_ca_certificate  = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
    load_config_file        = false
  }
}

# Create Static Public IP Address to be used by Nginx Ingress
# - Default basic creation uses sku of Basic - https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip
# - OT docs suggest this needs to be "Standard" - Page 20, section 4.1.1.3
resource "azurerm_public_ip" "nginx_ingress" {
  name                = "nginx-ingress-pip"
  location            = azurerm_kubernetes_cluster.aks.location
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.name_prefix
}

# Install Nginx Ingress using Helm Chart
resource "helm_release" "nginx-ingress" {
  name                = "nginx-ingress"
  repository          = "https://charts.helm.sh/stable"
  chart               = "nginx-ingress"

  set {
    name  = "rbac.create"
    value = "true"
  }

  set {
    name  = "controller.service.loadBalancerIP"
    value = azurerm_public_ip.nginx_ingress.ip_address
  }
}
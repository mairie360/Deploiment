# Role for database in dev environment
path "auth/kubernetes/role/database-dev" {
  capabilities = ["create", "update"]
  data = {
    bound_service_account_names      = ["database"]
    bound_service_account_namespaces = ["dev"]
    policies = ["database-dev", "shared-db-coreAPI-dev"]
  }
}

# Role for database in staging environment
path "auth/kubernetes/role/database-staging" {
  capabilities = ["create", "update"]
  data = {
    bound_service_account_names      = ["database"]
    bound_service_account_namespaces = ["staging"]
    policies = ["database-staging", "shared-db-coreAPI-staging"]
  }
}

# Role for database in prod environment
path "auth/kubernetes/role/database-prod" {
  capabilities = ["create", "update"]
  data = {
    bound_service_account_names      = ["database"]
    bound_service_account_namespaces = ["prod"]
    policies = ["database-prod", "shared-db-coreAPI-prod"]
  }
}

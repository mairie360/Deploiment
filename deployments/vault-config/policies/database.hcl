# Database dev
path "secret/mairie360/database/dev/*" {
  capabilities = ["read"]
}

# Database staging
path "secret/mairie360/database/staging/*" {
  capabilities = ["read"]
}

# Database prod
path "secret/mairie360/database/prod/*" {
  capabilities = ["read"]
}

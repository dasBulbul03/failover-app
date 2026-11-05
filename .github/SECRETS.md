# Required GitHub Secrets

## Azure Secrets

| Secret | Description | How to get |
|--------|-------------|------------|
| `AZURE_CREDENTIALS` | Service principal JSON | `az ad sp create-for-rbac --name failover-app-sp --role contributor --scopes /subscriptions/{id} --json-auth` |
| `AZURE_WEBAPP_NAME` | App Service name | From Bicep deployment output |
| `AZURE_RESOURCE_GROUP` | Resource group name | e.g., `failover-rg` |
| `ACR_LOGIN_SERVER` | ACR login server | e.g., `failoverapp.azurecr.io` |
| `ACR_USERNAME` | ACR admin username | From Azure Portal → ACR → Access keys |
| `ACR_PASSWORD` | ACR admin password | From Azure Portal → ACR → Access keys |
| `TM_PROFILE_NAME` | Traffic Manager profile name | From deployment |

## AWS Secrets

| Secret | Description | How to get |
|--------|-------------|------------|
| `AWS_ACCESS_KEY_ID` | IAM user access key | From IAM → Users → Security credentials |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key | From IAM → Users → Security credentials |
| `APP_RUNNER_ROLE_ARN` | App Runner IAM role ARN | From Terraform output |
| `AWS_APP_URL` | App Runner URL | From Terraform output |

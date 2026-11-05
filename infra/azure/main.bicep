@description('Base name for all resources')
param appName string = 'failover-app'

@description('Azure region')
param location string = resourceGroup().location

@description('PostgreSQL admin password')
@secure()
param pgAdminPassword string

@description('PostgreSQL admin username')
param pgAdminUser string = 'pgadmin'

var appServicePlanName = '${appName}-plan'
var webAppName = '${appName}-${uniqueString(resourceGroup().id)}'
var pgServerName = '${appName}-pg-${uniqueString(resourceGroup().id)}'
var dbName = 'failoverdb'

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

// PostgreSQL Flexible Server
resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: pgServerName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPassword
    version: '16'
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

// PostgreSQL Database
resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: pgServer
  name: dbName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.UTF8'
  }
}

// Allow Azure services firewall rule
resource pgFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: pgServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Web App
resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: true
      healthCheckPath: '/api/health'
      appSettings: [
        {
          name: 'DATABASE_URL'
          value: 'postgresql://${pgAdminUser}:${pgAdminPassword}@${pgServer.properties.fullyQualifiedDomainName}:5432/${dbName}?sslmode=require'
        }
        {
          name: 'APP_ENV'
          value: 'azure'
        }
        {
          name: 'REGION'
          value: location
        }
        {
          name: 'NODE_ENV'
          value: 'production'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
      ]
    }
    httpsOnly: true
  }
  dependsOn: [pgDatabase]
}

output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output webAppName string = webAppName
output pgServerName string = pgServerName
output pgConnectionString string = 'postgresql://${pgAdminUser}:${pgAdminPassword}@${pgServer.properties.fullyQualifiedDomainName}:5432/${dbName}?sslmode=require'

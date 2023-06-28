targetScope = 'subscription'

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the workload that is being deployed. Up to 10 characters long.')
@minLength(2)
@maxLength(10)
param workloadName string

@description('The name of the environment (e.g. "dev", "test", "prod", "uat", "dr", "qa"). Up to 8 characters long.')
@maxLength(8)
param environment string

@description('The location where the resources will be created.')
param location string = deployment().location

@description('Optional. The name of the resource group to create the resources in. If set, it overrides the name generated by the template.')
param hubResourceGroupName string = ''

@description('Optional. The tags to be assigned to the created resources.')
param tags object = {}

@description('CIDR of the hub virtual network.')
param vnetAddressPrefixes array

@description('Enable or disable the creation of the Azure Bastion.')
param enableBastion bool

@description('CIDR to use for the Azure Bastion subnet.')
param bastionSubnetAddressPrefix string

@description('The size of the jump box virtual machine to create. See https://learn.microsoft.com/azure/virtual-machines/sizes for more information.')
param vmSize string

@description('The username to use for the jump box.')
param vmAdminUsername string

@description('The password to use for the jump box.')
@secure()
param vmAdminPassword string

@description('The SSH public key to use for the jump box. Only relevant for Linux.')
@secure()
param vmLinuxSshAuthorizedKeys string

@description('The OS of the jump box virtual machine to create. If set to "none", no jump box will be created.')
@allowed([ 'linux', 'windows', 'none' ])
param vmJumpboxOSType string = 'none'

@description('Optional. The name of the subnet to create for the jump box. If set, it overrides the name generated by the template.')
param vmSubnetName string = 'snet-jumpbox'

@description('CIDR to use for the jump box subnet.')
param vmJumpBoxSubnetAddressPrefix string

// ------------------
// VARIABLES
// ------------------

//Subnet definition taking in consideration feature flags
var defaultSubnets = []

// This cannot be another value
var bastionSubnetName = 'AzureBastionSubnet'

// Append optional bastion subnet, if required
var subnets = enableBastion ? concat(defaultSubnets, [
    {
      name: bastionSubnetName
      properties: {
        addressPrefix: bastionSubnetAddressPrefix
      }
    }
  ]) : defaultSubnets

//Append optional jumpbox subnet, if required
var vnetSubnets = vmJumpboxOSType != 'none' ? concat(subnets, [
    {
      name: vmSubnetName
      properties: {
        addressPrefix: vmJumpBoxSubnetAddressPrefix
      }
    }
  ]) : subnets

//used only to override the RG name - because it is created at the subscription level, the naming module cannot be loaded/used
var namingRules = json(loadTextContent('../../../../shared/bicep/naming/naming-rules.jsonc'))
var rgHubName = !empty(hubResourceGroupName) ? hubResourceGroupName : '${namingRules.resourceTypeAbbreviations.resourceGroup}-${workloadName}-hub-${environment}-${namingRules.regionAbbreviations[toLower(location)]}'

// ------------------
// RESOURCES
// ------------------

@description('The hub resource group. This would normally be already provisioned by your platform team.')
resource hubResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgHubName
  location: location
  tags: tags
}

@description('User-configured naming rules')
module naming '../../../../shared/bicep/naming/naming.module.bicep' = {
  scope: hubResourceGroup
  name: take('01-sharedNamingDeployment-${deployment().name}', 64)
  params: {
    uniqueId: uniqueString(hubResourceGroup.id)
    environment: environment
    workloadName: workloadName
    location: location
  }
}

@description('The virtual network used as the stand-in for the regional hub. This would normally be already provisioned by your platform team.')
module vnetHub '../../../../shared/bicep/vnet.bicep' = {
  name: take('vnetHub-${deployment().name}', 64)
  scope: hubResourceGroup
  params: {
    name: naming.outputs.resourcesNames.vnetHub
    location: location
    subnets: vnetSubnets
    vnetAddressPrefixes: vnetAddressPrefixes
    tags: tags
  }
}

@description('An optional Azure Bastion deployment for jump box access. This would normally be already provisioned by your platform team.')
module bastion './modules/bastion.bicep' = if (enableBastion) {
  name: take('bastion-${deployment().name}', 64)
  scope: hubResourceGroup
  params: {
    location: location
    tags: tags
    bastionName: naming.outputs.resourcesNames.bastion
    bastionNetworkSecurityGroupName: naming.outputs.resourcesNames.bastionNsg
    bastionPublicIpName: naming.outputs.resourcesNames.bastionPip
    bastionSubnetName: bastionSubnetName
    bastionSubnetAddressPrefix: bastionSubnetAddressPrefix
    bastionVNetName: vnetHub.outputs.vnetName
  }
}

@description('An optional Linux virtual machine deployment to act as a jump box.')
module jumpboxLinuxVM './modules/vm/linux-vm.bicep' = if (vmJumpboxOSType == 'linux') {
  name: take('vm-linux-${deployment().name}', 64)
  scope: hubResourceGroup
  params: {
    location: location
    tags: tags
    vmName: naming.outputs.resourcesNames.vmJumpBox
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmSshPublicKey: vmLinuxSshAuthorizedKeys
    vmSize: vmSize
    vmVnetName: vnetHub.outputs.vnetName
    vmSubnetName: vmSubnetName
    vmSubnetAddressPrefix: vmJumpBoxSubnetAddressPrefix
    vmNetworkInterfaceName: naming.outputs.resourcesNames.vmJumpBoxNic
    vmNetworkSecurityGroupName: naming.outputs.resourcesNames.vmJumpBoxNsg
  }
}

@description('An optional Windows virtual machine deployment to act as a jump box.')
module jumpboxWindowsVM './modules/vm/windows-vm.bicep' = if (vmJumpboxOSType == 'windows') {
  name: take('vm-windows-${deployment().name}', 64)
  scope: hubResourceGroup
  params: {
    location: location
    tags: tags
    vmName: naming.outputs.resourcesNames.vmJumpBox
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmSize: vmSize
    vmVnetName: vnetHub.outputs.vnetName
    vmSubnetName: vmSubnetName
    vmSubnetAddressPrefix: vmJumpBoxSubnetAddressPrefix
    vmNetworkInterfaceName: naming.outputs.resourcesNames.vmJumpBoxNic
    vmNetworkSecurityGroupName: naming.outputs.resourcesNames.vmJumpBoxNsg
  }
}

// ------------------
// OUTPUTS
// ------------------

@description('The resource ID of hub virtual network.')
output hubVNetId string = vnetHub.outputs.vnetId

@description('The name of the hub resource group.')
output resourceGroupName string = hubResourceGroup.name
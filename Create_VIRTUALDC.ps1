# Parameters
$location = 'westus'
$dnsServer = @("10.30.5.15", "10.20.100.15")
$onPremisesIPAddress = "108.15.104.71" # The IP address of your on-premises VPN device. Your VPN device cannot be located behind a NAT
$onPremisesAddressPrefix = @("10.11.0.0/16", "10.20.0.0/16", "10.30.0.0/16", "10.35.0.0/16", "10.40.0.0/16", "10.99.0.0/16", "10.80.0.0/16", "10.60.0.0/16", "10.70.0.0/16") # The on-premises address space

# Internal Variables
$rgName = "AZ_" + $location 


function createRedisCache($resourceGroupName, $location, $name) {
    $name = 'redis' + $location + $name
    $redis = (Get-AzureRmRedisCache -ResourceGroupName $resourceGroupName | where { $_.Name -like ($name + '*' )})
    if ($redis) {
        Write-Host Redis Cache $name already exists
        return
    }

    $random = Get-Random
    $name = $name + $random
    New-AzureRmRedisCache -ResourceGroupName $resourceGroupName -Name $name -Location $location -Size C0 -Sku Basic
}

# ***** Create the Resource Group *****
New-AzureRMResourceGroup -Name $rgname -Location $location

# ***** Create the Virtual Network with VPN gateway *****
# https://azure.microsoft.com/en-us/documentation/articles/vpn-gateway-create-site-to-site-rm-powershell/
$subnetGateway = New-AzureRmVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix 10.36.64.0/28 # GatewaySubnet must be /28 or /29
$subnetDev = New-AzureRmVirtualNetworkSubnetConfig -Name 'Development' -AddressPrefix 10.36.65.0/24
$subnetTest = New-AzureRmVirtualNetworkSubnetConfig -Name 'Test' -AddressPrefix 10.36.66.0/24
$subnetProduction = New-AzureRmVirtualNetworkSubnetConfig -Name 'Production' -AddressPrefix 10.36.67.0/24
$subnetDMZ = New-AzureRmVirtualNetworkSubnetConfig -Name 'DMZ' -AddressPrefix 10.36.126.0/24
# Create the virtual network
New-AzureRmVirtualNetwork -Name $rgName -ResourceGroupName $rgName -Location $location -AddressPrefix 10.36.64.0/18 -Subnet $subnetGateway,$subnetDev,$subnetTest,$subnetProduction,$subnetDMZ -DnsServer $dnsServer
# Create the local network
New-AzureRmLocalNetworkGateway -Name LocalNetworkGateway -ResourceGroupName $rgName -Location $location -GatewayIpAddress $onPremisesIPAddress -AddressPrefix $onPremisesAddressPrefix

# Create the redis cache for this network
createRedisCache -resourceGroupName $rgName -location $location -name 'DevTest'
createRedisCache -resourceGroupName $rgName -location $location -name 'Prod'

# Allocate public IP Address
$gwpip= New-AzureRmPublicIpAddress -Name PublicIpAddress -ResourceGroupName $rgName -Location $location -AllocationMethod Dynamic

# Create the gateway IP address configuration; be sure to read the existing vnet that has been allocated (not the defined instances above)
$vnet = Get-AzureRmVirtualNetwork -Name $rgName -ResourceGroupName $rgName
$subnetGateway = Get-AzureRmVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
$gwipconfig = New-AzureRmVirtualNetworkGatewayIpConfig -Name gwipconfig -Subnet $subnetGateway -PublicIpAddress $gwpip
# Create the gateway - this will take some time
New-AzureRmVirtualNetworkGateway -Name VirtualNetworkGateway -ResourceGroupName $rgName -Location $location -IpConfigurations $gwipconfig -GatewayType Vpn -VpnType RouteBased

# NOTE: Configure that VPN device at this time, note what the shared key is
$sharedKey = 'mTenO8sj3Wd6KBotkJ8bEFCRpqgyoVPmiTHJ'
# Create the VPN connection
$gateway = Get-AzureRmVirtualNetworkGateway -ResourceGroupName $rgName -Name VirtualNetworkGateway
$localNetworkGateway = Get-AzureRMLocalNetworkGateway -Name LocalNetworkGateway -ResourceGroupName $rgName
New-AzureRmVirtualNetworkGatewayConnection -Name VirtualNetworkGatewayConnection -ResourceGroupName $rgName -Location $location -VirtualNetworkGateway1 $gateway -LocalNetworkGateway2 $localNetworkGateway -ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedKey

# Verify a VPN connection
Get-AzureRmVirtualNetworkGatewayConnection -Name VirtualNetworkGatewayConnection -ResourceGroupName $rgName 


# Login-AzureRmAccount
# Get-AzureRmSubscription -SubscriptionName "TESSCO_Main" | Select-AzureRmSubscription

# PowerShell script to create the same two-NIC VM as the assoicated json template.
# Author, Jonathan Kyle, RDA

##Switch-AzureMode AzureResourceManager

# Parameters


function createResourceGroup($name, $location) {
    $rg = (Get-AzureRmResourceGroup -Location $location | where { $_.ResourceGroupName -eq $name })
    if ($rg) {
        Write-Host Resource Group $name Already Exists
        return $rg
    }
    Write-Host Creating Resource Group: $name
    $rg = New-AzureRMResourceGroup -Name $name -Location $location 
    return $rg
}


function getOrCreateLoadBalancer($resourceGroupName, $location, $name) {
    $lbName = 'lb' + $name
    $lb = (Get-AzureRmLoadBalancer -ResourceGroupName $resourceGroupName | where { $_.Name -eq $lbName })
    if ($lb) {
       Write-Host Load Balancer $name Already Exists
       return $lb
    }

    Write-Host Creating Load Balancer: $name
    $publicIpName = 'publicIp' + $name
    $publicIP = New-AzureRMPublicIpAddress -ResourceGroupName $resourceGroupName -name $publicIpName -location $location -AllocationMethod Dynamic 

    $frontendName = 'frontend' + $name
    $frontend = New-AzureRMLoadBalancerFrontendIpConfig -Name $frontendName -PublicIpAddress $publicIP 

    $backendAddressPoolName = 'backendAddressPool' + $name
    $backendAddressPool = New-AzureRMLoadBalancerBackendAddressPoolConfig -Name $backendAddressPoolName 

    #$healthProbe = New-AzureRmLoadBalancerProbeConfig -Name "HealthProbe" -RequestPath "HealthProbe.aspx" -Protocol http -Port 80 -IntervalInSeconds 15 -ProbeCount 2
    $lbrule = New-AzureRmLoadBalancerRuleConfig -Name "HTTP" -FrontendIpConfiguration $frontend -BackendAddressPool $backendAddressPool -Protocol Tcp -FrontendPort 80 -BackendPort 80 #-Probe $healthProbe

    $lb = New-AzureRMLoadBalancer -Name $lbName -ResourceGroupName $resourceGroupName -Location $location -FrontendIpConfiguration $frontend -BackendAddressPool $backendAddressPool -LoadBalancingRule $lbrule
    
    return $lb;
}


function createStorageAccount($resourceGroupName, $name, $type, $location) {
    # ***** Create the Storage Account *****
    $name = $name.ToLower()
    $storageAccount = (Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName | where { $_.StorageAccountName -like ($name + '*') })
    if ($storageAccount) {
        Write-Host Storage Account $storageAccount.StorageAccountName Already Exists
        return $storageAccount
    }

    Write-Host Creating Storage: $name
    $random = Get-Random
    $storageAccount = New-AzureRmStorageAccount -Name ($name + $random) -ResourceGroupName $resourceGroupName –Type $type -Location $location
    Write-Host VM Storage Created

    return $storageAccount
}


function copyVMTemplate($templateContainer, $srcPrefix, $destStorageAccount) {
    # Copy the source image VHD
    Write-Host ***** Copy Source Image VHD $srcPrefix

    if (!(Get-AzureStorageContainer -Context $destStorageAccount.Context  | where { $_.Name -eq $templateContainer.Name } )) {
        New-AzureStorageContainer -Context $destStorageAccount.Context -Name $templateContainer.Name
    }
    
    $storageBlob = (Get-AzureStorageBlob -Context $templateContainer.Context -Container $templateContainer.Name -Prefix $srcPrefix | Sort LastModified -Descending)[0]

    $existing = Get-AzureStorageBlob -Context $destStorageAccount.Context -Container $templateContainer.Name | Where {$_.Name -eq $storageBlob.Name }
    if ($existing) {
        Write-Host $storageBlob.ICloudBlob.Uri already exists
    } 
    else {
        Write-Host Copy $storageBlob.ICloudBlob.Uri
        $blobCopy = Start-CopyAzureStorageBlob -CloudBlob $storageBlob.ICloudBlob -DestContainer $templateContainer.Name -Context $templateContainer.Context -DestContext $destStorageAccount.Context -Force
        Write-Host $blobCopy
        $blobCopy | Get-AzureStorageBlobCopyState -WaitForComplete
    }

    Write-Host ***** Source Image VHD Copied
    
    $destBlob = Get-AzureStorageBlob -Context $destStorageAccount.Context -Container $templateContainer.Name -Prefix $srcPrefix;
    return $destBlob
}


function createVM($resourceGroupName, $name, $dcResourceGroupName, $dcSubnetName, $location, $username, $password, $vmSize, $srcPrefix, $numNics, $loadbalancer, $dataDrive) {
    $osDiskName = 'OSDisk.vhd'
    $nicNames = @()
    For ($i=0;$i -lt $numNics; $i++) {
        $nicNames += 'nic' + $name + '_' + $i
    }

    $vmName = 'vm' + $name

    # Check if the VM already exists
    $existingVM = (Get-AzureRmVM  -ResourceGroupName $resourceGroupName | where { $_.Name -eq $vmName })
    if ($existingVM) {
        Write-Host Virtual Machine $vmName already exists
        return
    }

    # Create Storage Account
    $saType = 'Standard_LRS'
    $storageAccount = createStorageAccount -resourceGroupName $rgName -Name $vmName -type $saType -location $location

    # Create credentials
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force;
    $cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword);   

    # Copy Template VHDs from Backup to the storage account for the VMs
    $templateContainer = getTemplateContainer -containerName 'system'
    $osDiskTemplateBlob = copyVMTemplate -templateContainer $templateContainer -srcPrefix $srcPrefix -destStorageAccount $storageAccount

    # Create the NICs if they don't exist already
    $subnet = Get-AzureRmVirtualNetwork -ResourceGroupName $dcResourceGroupName | Get-AzureRmVirtualNetworkSubnetConfig -Name $dcSubnetName
    $nics = @()
    For ($i=0;$i -lt $numNics; $i++) {
        $nicName = $nicNames[$i]
        $nic = (Get-AzureRmNetworkInterface -ResourceGroupName $resourceGroupName | where { $_.Name -eq $nicName })
        if (!$nic) {
            Write-Host Creating Network Interface $nicName
            $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $resourceGroupName -Location $location -Subnet $subnet
        }
        $nics += $nic
    }

    # Create Load Balancer and add NICs to address pool, and create availability set for VM, if specified
    $availabilitySet
    if ($loadbalancer) {
        $lb = getOrCreateLoadBalancer -resourceGroupName $resourceGroupName -location $location -name $loadbalancer

        For ($i=0;$i -lt $numNics; $i++) {
            
            $nic = $nics[$i]

            #$inboundNatRuleRDPName = 'natRuleRDP' + $loadbalancer
            #$inboundNatRuleRDP = New-AzureRMLoadBalancerInboundNatRuleConfig -Name $inboundNatRuleRDPName -FrontendIPConfiguration $frontend -Protocol Tcp -FrontendPort 50001 -BackendPort 3389 -IdleTimeoutInMinutes 15 
            #$nic.IpConfigurations[0].LoadBalancerInboundNatRules.Add($lb.InboundNatRules[0]);

            # Load balancers can only reference primary interfaces; otherwise error: "<load balancer> references a backend IP configuration on secondary network interface "
            if ($i -eq 0) {
                if ($nic.IpConfigurations[0].LoadBalancerBackendAddressPools.Count -eq 0) {
                    $nic.IpConfigurations[0].LoadBalancerBackendAddressPools.Add($lb.BackendAddressPools[0])
                    $nic | Set-AzureRmNetworkInterface
                }
            }
        }

        $avSetName = 'avSet' + $loadbalancer
        $availabilitySet = (Get-AzureRmAvailabilitySet -ResourceGroupName $resourceGroupName | where { $_.Name -eq $avSetName })
        if (!$availabilitySet) {
            $availabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $resourceGroupName -Name $avSetName -Location $location
        }
    }

    # Create the VM
    $vm
    if ($availabilitySet) {
        $vm = New-AzureRmVMConfig -VMName $vmName -VMSize $vmSize -AvailabilitySetId $availabilitySet.Id
    }
    else {
        $vm = New-AzureRmVMConfig -VMName $vmName -VMSize $vmSize
    }
    
    $vm = Set-AzureRmVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
    For ($i=0;$i -lt $numNics; $i++) {
        $nic = $nics[$i]
        if ($i -eq 0) {
            $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id -Primary
        }
        else {
            $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id
        }
    }  
    $osDiskUri = $storageAccount.PrimaryEndpoints.Blob.ToString() + "vhds/" + $osDiskName
    $vm = Set-AzureRmVMOSDisk -VM $vm -Name $vmName -VhdUri $osDiskUri -CreateOption fromImage -SourceImageUri $osDiskTemplateBlob.ICloudBlob.Uri -Windows
    if ($dataDrive) {
        # Add a 200 GB additional data disk
        $diskSize=200
        $diskLabel="DataDisk"
        $diskName="DataDisk"
        $vhdURI=$storageAccount.PrimaryEndpoints.Blob.ToString() + "vhds/" + $vmName + $diskName  + ".vhd"
        $vm = Add-AzureRmVMDataDisk -VM $vm -Name $diskLabel -DiskSizeInGB $diskSize -VhdUri $vhdURI -CreateOption empty
    }

    Write-Host ***** Creating $name VM: $vmName from template $osDiskTemplateBlob.ICloudBlob.Uri 

    New-AzureRmVM -ResourceGroupName $resourceGroupName -Location $location -VM $vm

    # Cleanup the Templates
    cleanupVMTemplate -storageAccount $storageAccount -name $templateContainer.Name
}


function cleanupVMTemplate($storageAccount, $name) {
    Remove-AzureStorageContainer -Context $storageAccount.Context -Name $name -Force
}


function getTemplateContainer($containerName) {
    $srcResourceGroupName = 'Backups'
    $srcStorageAccountName = 'tesscotemplates'
    $storageAccount= Get-AzureRmStorageAccount -ResourceGroupName $srcResourceGroupName -Name $srcStorageAccountName
    $templateContainer = Get-AzureStorageContainer -Contex $storageAccount.Context -Name $containerName
    return $templateContainer
}

function importDatabase($context, $databaseName, $templateContainer, $blobName) {
    $db = Get-AzureSqlDatabase -ConnectionContext $context -DatabaseName $databaseName
    if ($db) {
        Write-Host Database $databaseName Already Exists
        return
    }
    $importRequest = Start-AzureSqlDatabaseImport -SqlConnectionContext $context -StorageContainer $templateContainer -Edition Basic -DatabaseName $databaseName -BlobName $blobName
    Write-Host Started Restoring $databaseName. RequestGuid = $importRequest.RequestGuid
    return $importRequest
}

function setupSQL($resourceGroupName, $location, $username, $password, $backupPath) {
    # https://azure.microsoft.com/en-us/documentation/articles/sql-database-import-powershell/
    $random = Get-Random
    $name = 'sql' + $random
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force;
    $cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword);   

    $sqlServer = Get-AzureRmSqlServer -ResourceGroupName $resourceGroupName | where { $_.ServerName -like 'sql*' } | Sort LastModified -Descending
    if ($sqlServer) {
        Write-Host SQL Server Already Exists
        $sqlServer = $sqlServer[0]
     #   return
    }
    else {
        Write-Host Create SQL Server $name
        $sqlServer = New-AzureRmSqlServer -ResourceGroupName $resourceGroupName -Location $location -ServerName $name -ServerVersion "12.0" -SqlAdministratorCredentials $cred

        New-AzureRmSqlServerFirewallRule -ResourceGroupName $resourceGroupName -ServerName $name -AllowAllAzureIPs

        # to manage the database we have to add the current ip address to the list of allowed ip addresses to the list.
        # using the .Net web client object to get the ip address ad adding it as firewall rule
        $wc=New-Object net.webclient
        $ip = $wc.downloadstring("http://checkip.dyndns.com") -replace "[^\d\.]" 
        # fetchng todays date
        $todaysdatetime = Get-Date
        # creating a firewall rule name with a timestamp of todays date.
        $firewallRulename = "ClientIpAddress" + $todaysdatetime.Year +"-" + $todaysdatetime.Month +"-" + $todaysdatetime.Day +"-" + $todaysdatetime.Hour +"-" + $todaysdatetime.Minute +"-"+ $todaysdatetime.Second +"-" + $todaysdatetime.Millisecond 
        
        #add the firewall rule
        $sqlServer | New-AzureSqlDatabaseServerFirewallRule -RuleName $firewallRulename -StartIPAddress $ip -EndIPAddress $ip 
    }

    $templateContainer = getTemplateContainer -containerName 'sql'
    $sqlContext = New-AzureSqlDatabaseServerContext -ServerName $sqlServer.ServerName -Credential $cred

    Write-Host Restoring Databases
    $importRequests = @() # create array of import reqeusts
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'TesscoWeb' -blobName ($backupPath + '\TesscoWeb_QA.bacpac')
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'Sitecore8_Master' -blobName ($backupPath + '\Sitecore8_Master_QA.bacpac')
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'Sitecore8_ActiveCommerce' -blobName ($backupPath + '\Sitecore8_ActiveCommerce_QA.bacpac')
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'Sitecore8_Web' -blobName ($backupPath + '\Sitecore8_Web_QA.bacpac')
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'Sitecore8_Reporting' -blobName ($backupPath + '\Sitecore8_Reporting_QA.bacpac')
    $importRequests += importDatabase -context $sqlContext -templateContainer $templateContainer -databaseName 'Sitecore8_Core' -blobName ($backupPath + '\Sitecore8_Core_QA.bacpac')

    $importRequests | ForEach-Object `
    {
        $status = Get-AzureSqlDatabaseImportExportStatus -Request $_
        Write-Host RequestGuid: $_.RequestGuid
        Write-Host $status.ToString()
    }
}


function restoreSitecoreProd($name, $location, $deliveryVmId) {

    $rgName = 'SITECORE_PROD_' + $name   
    createResourceGroup -name $rgName -location $location

    # Create the VM
    $dcResourceGroupName = 'AZ_' + $location
    $dcSubnetNameDMZ = 'DMZ'
    $dcSubnetNameProduction = 'Production'
    $username = 'sitecoreAdmin'
    $password = 'P2ssword!'
    $vmSize = 'Standard_DS11'

    # Setup the SQL Server
    setupSQL -resourceGroupName $rgName -location $location -username $username -password $password -backupPath '2015-12-14'

    # Create Sitecore Delivery VMs
    $srcPrefixSitecore = 'Microsoft.Compute/Images/sitecoretemplates/dev-osDisk'
    $vmNameCMS = 'CMS'
    createVM -resourceGroupName $rgName -location $location -name $vmNameCMS -dcResourceGroupName $dcResourceGroupName -dcSubnetName $dcSubnetNameProduction -password $password -username $username -srcPrefix $srcPrefixSitecore -vmSize $vmSize -numNics 1
    $vmNameDelivery = 'Delivery' + $deliveryVmId # There can be multiple Delivery VMs
    $loadbalancer = 'Delivery'
    createVM -resourceGroupName $rgName -location $location -name $vmNameDelivery -dcResourceGroupName $dcResourceGroupName -dcSubnetName $dcSubnetNameDMZ -password $password -username $username -srcPrefix $srcPrefixSitecore -vmSize $vmSize -numNics 2 -loadbalancer $loadbalancer

        # Create  Coveo VM
    $vmNameCoveo = 'Coveo'
    $srcPrefixCoveo = 'Microsoft.Compute/Images/coveotemplates/dev-osDisk'
    createVM -resourceGroupName $rgName -location $location -name $vmNameCoveo -dcResourceGroupName $dcResourceGroupName -dcSubnetName $dcSubnetNameProduction -password $password -username $username -srcPrefix $srcPrefixCoveo -vmSize $vmSize -storageAccount $coveoVMStorageAccount -numNics 1 -dataDrive
}


restoreSitecoreProd -Name 'dr_ver02' -location 'westus' -deliveryVmId '1'

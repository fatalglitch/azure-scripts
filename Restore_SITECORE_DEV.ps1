# Login-AzureRmAccount
# Get-AzureRmSubscription -SubscriptionName "TESSCO_Main" | Select-AzureRmSubscription

# PowerShell script to create the same two-NIC VM as the assoicated json template.
# Author, Jonathan Kyle, RDA

##Switch-AzureMode AzureResourceManager

# Parameters


function createResourceGroup($name, $location) {
    $rg = Get-AzureRmResourceGroup -Name $name -Location $location
    if ($rg) {
        Write-Host Resource Group Already Exists
        return $rg
    }
    Write-Host 'Creating Resource Group: ' $name
    $rg = New-AzureRMResourceGroup -Name $name -Location $location 
    return $rg
}


function createPublicNetworkInterface() {
    # Create the network interface
    # $publicIPWeb = New-AzureRmPublicIpAddress -Name 'PublicIP' -ResourceGroupName $rgName -Location $location -AllocationMethod Dynamic
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

    #$srcAccount = Get-AzureRmStorageAccount -ResourceGroupName $srcResourceGroupName -Name $srcStorageAccountName

    if (!(Get-AzureStorageContainer -Context $destStorageAccount.Context  | where { $_.Name -eq $templateContainer.Name } )) {
        New-AzureStorageContainer -Context $destStorageAccount.Context -Name $templateContainer.Name
    }
    
    $storageBlob = (Get-AzureStorageBlob -Context $templateContainer.Context -Container $templateContainer.Name -Prefix $srcPrefix | Sort LastModified -Descending)[0]

    $storageBlob | ForEach-Object `
    { 
        Write-Host $_.ICloudBlob.Uri
        $blobCopy = Start-CopyAzureStorageBlob -CloudBlob $_.ICloudBlob -DestContainer $templateContainer.Name -Context $templateContainer.Context -DestContext $destStorageAccount.Context -Force
        $blobCopy | Get-AzureStorageBlobCopyState -WaitForComplete
        $BlobCpyAry += $BlobCpyAry
    }

    Write-Host ***** Source Image VHD Copied
    
    $destBlob = Get-AzureStorageBlob -Context $destStorageAccount.Context -Container $templateContainer.Name -Prefix $srcPrefix;
    return $destBlob
}


function createVM($resourceGroupName, $name, $dcResourceGroupName, $dcSubnetName, $location, $username, $password, $vmSize, $storageAccount, $srcPrefix, $dataDrive) {
    $osDiskName = 'OSDisk.vhd'
    $nicName = 'nic' + $name
    $vmName = 'vm' + $name

    # Check if the VM already exists
    $existingVM = (Get-AzureRmVM  -ResourceGroupName $resourceGroupName | where { $_.Name -eq $vmName })
    if ($existingVM) {
        Write-Host Virtual Machine $vmName already exists
        return
    }

    # Create credentials
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force;
    $cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword);   

    # Copy Template VHDs from Backup to the storage account for the VMs
    $templateContainer = getTemplateContainer -containerName 'system'
    $osDiskTemplateBlob = copyVMTemplate -templateContainer $templateContainer -srcPrefix $srcPrefix -destStorageAccount $storageAccount

    Write-Host ***** Creating Web VM: $vmName from template $osDiskTemplateBlob.ICloudBlob.Uri 
    # Create the NIC if it doesn't exist already
    $nic = (Get-AzureRmNetworkInterface -ResourceGroupName $resourceGroupName | where { $_.Name -eq $nicName })
    if (!$nic) {
        Write-Host Creating Network Interface $nicName

        $subnet = Get-AzureRmVirtualNetwork -ResourceGroupName $dcResourceGroupName | Get-AzureRmVirtualNetworkSubnetConfig -Name $dcSubnetName
        $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $resourceGroupName -Location $location -Subnet $subnet
    }

    # Create the VM
    $vm = New-AzureRmVMConfig -VMName $vmName -VMSize $vmSize
    $vm = Set-AzureRmVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
    $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id
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


function setupSQL($resourceGroupName, $location, $username, $password) {
    # https://azure.microsoft.com/en-us/documentation/articles/sql-database-import-powershell/
    $random = Get-Random
    $name = 'sql' + $random
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force;
    $cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword);   

    $sqlServer = (Get-AzureRmSqlServer -ResourceGroupName $resourceGroupName | where { $_.ServerName -like 'sql*' })
    if ($sqlServer) {
        Write-Host SQL Server Already Exists
        return
    }

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
    # create a new datavase. which is a web edition/ you can also create

    $templateContainer = getTemplateContainer -containerName 'sql'
    $sqlContext = New-AzureSqlDatabaseServerContext -ServerName $name -Credential $cred

    $importRequests = @() # create array of import reqeusts
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "TesscoWeb" -BlobName "TesscoWeb_QA.bacpac"
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "Sitecore8_Master" -BlobName "Sitecore8_Master_QA.bacpac"
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "Sitecore8_ActiveCommerce" -BlobName "Sitecore8_ActiveCommerce_QA.bacpac"
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "Sitecore8_Web" -BlobName "Sitecore8_Web_QA.bacpac"
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "Sitecore8_Reporting" -BlobName "Sitecore8_Reporting_QA.bacpac"
    $importRequests += Start-AzureSqlDatabaseImport -SqlConnectionContext $sqlContext -StorageContainer $templateContainer -Edition Basic -DatabaseName "Sitecore8_Core" -BlobName "Sitecore8_Core_QA.bacpac"
    
    $importRequests | ForEach-Object `
    {
        $status = Get-AzureSqlDatabaseImportExportStatus -Request $_
        Write-Host $_
        Write-Host $status
    }
}


function restoreSitecoreDev($name, $location) {
    $rgName = 'SITECORE_DEV_' + $name
    
    createResourceGroup -name $rgName -location $location

    # Create Storage Accounts
    $saType = 'Standard_LRS'
    $saNameWeb = 'Web'
    $webVMStorageAccount = createStorageAccount -resourceGroupName $rgName -Name $saNameWeb -type $saType -location $location
    $saNameCoveo = 'Coveo'
    $coveoVMStorageAccount = createStorageAccount -resourceGroupName $rgName -Name $saNameCoveo -type $saType -location $location

    # Create the VMs
    $dcResourceGroupName = 'AZ_' + $location
    $dcSubnetName = 'Development'
    $username = 'sitecoreAdmin'
    $password = 'P2ssword!'
    $vmSize = 'Standard_DS11'

        # Create Web VM
    $vmNameWeb = 'Web'
    $srcPrefixSitecore = 'Microsoft.Compute/Images/sitecoretemplates/dev-osDisk'
    createVM -resourceGroupName $rgName -location $location -name $vmNameWeb -dcResourceGroupName $dcResourceGroupName -dcSubnetName $dcSubnetName -password $password -username $username -srcPrefix $srcPrefixSitecore -vmSize $vmSize -storageAccount $webVMStorageAccount

        # Create  Coveo VM
    $vmNameCoveo = 'Coveo'
    $srcPrefixCoveo = 'Microsoft.Compute/Images/coveotemplates/dev-osDisk'
    createVM -resourceGroupName $rgName -location $location -name $vmNameCoveo -dcResourceGroupName $dcResourceGroupName -dcSubnetName $dcSubnetName -password $password -username $username -srcPrefix $srcPrefixCoveo -vmSize $vmSize -storageAccount $coveoVMStorageAccount -dataDrive true

    
    # Setup the SQL Server
    setupSQL -resourceGroupName $rgName -location $location -username $username -password $password
}


restoreSitecoreDev -Name 'jkyle4' -location 'eastus'

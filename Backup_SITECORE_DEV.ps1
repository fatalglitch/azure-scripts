#*****  NOTE: THIS SCRIPT HAS HARD CODED VALUES, set them carefully

# See http://www.codeisahighway.com/how-to-capture-your-own-custom-virtual-machine-image-under-azure-resource-manager-api/
# In the VM, open a Powershell window and execute:        & "$Env:SystemRoot\system32\sysprep\sysprep.exe" /generalize /oobe /shutdown 
# ... or remotely execute:           Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /quiet'
# After the VM has shut down, deallocate it by executing:    Stop-AzureVM -ResourceGroupName 'CaptureVmImageRG' -Name 'CaptureVmImage'  
# Once Succeeded, set the generalized state by executing:    Set-AzureVM -ResourceGroupName 'CaptureVmImageRG' -Name 'CaptureVmImage' -Generalized  
# Once that OK status code, capture the image to a storage account:     Save-AzureVMImage -ResourceGroupName 'CaptureVmImageRG' -VMName 'CaptureVmImage' -DestinationContainerName 'mytemplates' -VHDNamePrefix 'template' -Path C:\temp\capturevmtest\SampleTemplate.json 


# Parameters
#$rgSource = 'SITECORE_PROD_ver01'
#$storageNameSource = 'vmcms2017585630'
#$vmName = 'vmCMS'


function captureVM($resourceGroupName, $vmName, $systemImageContainerName, $vhdNamePrefix) {
    # Stop the VM
    Write-Host ***** Stop VM $vmName
    Stop-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName

    # Set Generalized State
    Write-Host ***** Set Generalized State $vmName
    Set-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName -Generalized  

    # Capture the image to storage account.
    Write-Host ***** Capture VM Image $vmName
    Save-AzureRmVMImage -ResourceGroupName $resourceGroupName -VMName $vmName -DestinationContainerName 'sitecoretemplates' -VHDNamePrefix 'dev'
}

function copyVMImageToBackup($resourceGroupName, $vmName, $destinationBlobName) {
    $vm = Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $vmName
    
    $uri = [System.Uri]$vm.StorageProfile.OSDisk.SourceImage.Uri
    $sourceAccountName = $uri.Host.Split('.')[0]
    $sourceContainerName = $uri.LocalPath.Split('/')[1]

    # Copy the source image VHD
    Write-Host ***** Copy Source Image VHD 
    $rgDestination = 'Backups'
    $storageNameDestination = 'tesscotemplates'
    $destinationContainerName = 'system'

    $sourceAccount = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $sourceAccountName
    $sourceContainer = Get-AzureStorageContainer -Context $sourceAccount.Context -Name $sourceContainerName

    $destinationAccount = Get-AzureRmStorageAccount -ResourceGroupName $rgDestination -Name $storageNameDestination
    $destinationContainer = Get-AzureStorageContainer -Context $destinationAccount.Context -Name $destinationContainerName
    if (!$destinationContainer) 
    { 
        $destinationContainer = New-AzureStorageContainer -Context $destinationAccount.Context -Name $destinationContainerName
        $destinationContainer = Get-AzureStorageContainer -Context $destinationAccount.Context -Name $destinationContainerName
    }

    # Copy the captured VHD to the "Backup" resource group
    Get-AzureStorageBlob -Context $sourceAccount.Context -Container $sourceContainer.Name |
        ForEach-Object { 
            Write-Host $_.ICloudBlob.Uri
            $blobCopy = Start-CopyAzureStorageBlob -CloudBlob $_.ICloudBlob -DestContainer $destinationContainerName -Context $sourceAccount.Context -DestContext $destinationAccount.Context
            $blobCopy | Get-AzureStorageBlobCopyState -WaitForComplete
        }

    Write-Host ***** Source Image VHD Copied

}

$rgName = 'SITECORE_PROD_ver01'
$vmName = 'vmCMS'

# captureVM -resourceGroupName $rgName -vmName $vmName -systemImageContainerName 'sitecoretemplate' -vhdNamePrefix 'dev'
copyVMImageToBackup -resourceGroupName $rgName -vmName $vmName -destinationBlobName $vmName



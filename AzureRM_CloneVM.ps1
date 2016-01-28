## Microsoft Azure VM Cloning Script
## - Assumes that you are using Resource Manager
## Written by Tom Callahan <tcalla3@gmail.com> 01/21/2016
## Components and ideas pulled from various sources

#Forms Controls - https://technet.microsoft.com/en-us/library/ff730949.aspx
#Custom Forms Layouts - http://blogs.technet.com/b/stephap/archive/2012/04/23/building-forms-with-powershell-part-1-the-form.aspx
#More Powershell Visual - https://sysadminemporium.wordpress.com/2012/12/07/powershell-gui-for-your-scripts-episode-3/


# Variable definitions
$srcSubnetName = 'development' #Options are currently development, stage, production, dmz
$srcLocation = 'useast' #Options currently are useast, uswest
$destSubnetName = 'development' #Options are currently development, stage, production, dmz
$destLocation = 'useast' #Options currently are useast, uswest

function read-input($prompt, $title, $defaultvalue) {
Add-Type -assemblyname microsoft.visualbasic
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.VisualBasic")

$formatPrompt = Out-String -InputObject $prompt
#$response = [Microsoft.VisualBasic.Interaction]::InputBox($formatPrompt,$title, $defaultvalue, $x, $y)

#Get Imaging
#$imgsrc = [System.Net.WebRequest]::Create("http://www.wimax-industry.com/eq/images/tessco.gif")
#$resp = $imgsrc.GetResponse()
#$imgstream = $resp.GetResponseStream()
#$imgfil = New-Object System.IO.StreamReader $imgstream

$Form = New-Object System.Windows.Forms.Form
$Form.Text = $title
$Label = New-Object System.Windows.Forms.Label
$Label.Text = $prompt
$Label.Autosize = $True
$Label.BackColor = "Transparent"
$Form.AutoSizeMode = "GrowAndShrink"
$Form.StartPosition = "CenterScreen"
$Form.MinimizeBox = $False
$Form.MaximizeBox = $False

#$Image = [system.drawing.image]::FromStream($imgfil)
#$Form.BackgroundImage = $Image
#$Form.BackgroundImageLayout = "None"

$YesButton = New-Object System.Windows.Forms.Button
$YesButton.Location = New-Object System.Drawing.Size(75,120)
$YesButton.Size = New-Object System.Drawing.Size(75,23)
$YesButton.Text = "Yes"
$YesButton.Add_Click({$response='Y'; $Form.Close(); return $response})

$NoButton = New-Object System.Windows.Forms.Button
$NoButton.Location = New-Object System.Drawing.Size(150,120)
$NoButton.Size = New-Object System.Drawing.Size(75,23)
$NoButton.Text = "No"
$NoButton.Add_Click({$response='N'; $Form.Close()})

$Form.Controls.Add($Label)
$Form.Controls.Add($YesButton)
$Form.Controls.Add($NoButton)
$Form.ShowDialog()

Write-Host "Answer from inside function is" $response

return $response
}

function createResourceGroup($name, $location) {
    $rg = Get-AzureRmResourceGroup -Name $name -Location $location
    if ($rg) {
        Write-Output "Resource Group Already Exists"
        return $rg
    }
    Write-Output 'Creating Resource Group: ' $name
    $rg = New-AzureRMResourceGroup -Name $name -Location $location 
    return $rg
}

function findSourceVM($name) {
	$vmlist = Find-AzureRmResource -ResourceNameContains $name -ResourceType Microsoft.Compute/VirtualMachines
	IF ($vmlist.count -gt 1) {
		#Write-Output "Found multiple VM's which match, please choose:"
		Write-Output "Found more than one VM, this is not currently supported"
		#foreach($vm in $vmlist){
		#	$prompt = $vm | Format-Table Name, ResourceGroupName, Location | Out-String
		#	$answer = read-input -prompt $prompt -title 'Enter Input' -defaultvalue 'Is this the VM? (Y/N)'
		#	Write-Output "Answer was " $answer
		#	if (($answer -eq 'Y') -Or ($answer -eq 'y')) { 
		#		$vmlist = $vm
		#		return $vm
		#		break 
		#	}
		break
		}
		
		#IF ($vmlist.count -gt 1) {
		#	Write-Output "Must choose one, exiting..."
		#	break
		#}
	ELSE {
		$vm = $vmlist
		Write-Output "Found " + $vmlist.Name + "."
		return $vm
	}
}

findSourceVM -name 'Clone'
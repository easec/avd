$OutputFile = "$HOME/AVD-HostPools-Inventory.csv"

$Context = Get-AzContext
$SubscriptionId = $Context.Subscription.Id

# Hämta samtliga VM i prenumerationen en gång
$AllVMs = @(Get-AzVM -Status)

$Results = @(
    foreach ($Pool in Get-AzWvdHostPool) {

        $PoolRG = ($Pool.Id -split '/')[4]

        Write-Host "Host Pool: $($Pool.Name)" -ForegroundColor Cyan

        $Hosts = Get-AzWvdSessionHost `
            -ResourceGroupName $PoolRG `
            -HostPoolName $Pool.Name

        foreach ($HostEntry in $Hosts) {

            $HostFQDN = ($HostEntry.Name -split '/')[-1]
            $VMName = ($HostFQDN -split '\.')[0]

            $VMId = $HostEntry.ResourceId

            $VM = $null
            $VMRG = "N/A"
            $IP = "N/A"
            $VNet = "N/A"
            $Subnet = "N/A"
            $VMSize = "N/A"
            $PowerState = "Unknown"
            $ErrorInfo = ""

            try {
                # Matcha helst med Resource ID
                if ($VMId) {
                    $VM = $AllVMs |
                        Where-Object Id -eq $VMId |
                        Select-Object -First 1
                }

                # Reservmetod: matcha VM-namn
                if (-not $VM) {
                    $Matches = @(
                        $AllVMs | Where-Object {
                            $_.Name -ieq $VMName
                        }
                    )

                    if ($Matches.Count -eq 1) {
                        $VM = $Matches[0]
                    }
                    elseif ($Matches.Count -gt 1) {
                        throw "Multiple VMs found with name $VMName"
                    }
                    else {
                        throw "VM not found: $VMName"
                    }
                }

                $VMRG = $VM.ResourceGroupName
                $VMSize = $VM.HardwareProfile.VmSize

                $PowerState = (
                    $VM.Statuses |
                    Where-Object { $_.Code -like "PowerState/*" } |
                    Select-Object -First 1
                ).DisplayStatus

                # Hämta NIC
                $NICId = (
                    $VM.NetworkProfile.NetworkInterfaces |
                    Where-Object Primary -eq $true |
                    Select-Object -First 1
                ).Id

                if (-not $NICId) {
                    $NICId = $VM.NetworkProfile.NetworkInterfaces[0].Id
                }

                if (-not $NICId) {
                    throw "No NIC associated with VM"
                }

                $NIC = Get-AzNetworkInterface `
                    -ResourceId $NICId `
                    -ErrorAction Stop

                # Hämta primär IP-konfiguration
                $IPConfig = $NIC.IpConfigurations |
                    Where-Object Primary -eq $true |
                    Select-Object -First 1

                if (-not $IPConfig) {
                    $IPConfig = $NIC.IpConfigurations[0]
                }

                $IP = $IPConfig.PrivateIpAddress

                # Hämta VNet och Subnet
                $SubnetId = $IPConfig.Subnet.Id

                if ($SubnetId) {
                    $Subnet = ($SubnetId -split '/')[-1]
                    $VNet = ($SubnetId -split '/virtualNetworks/')[1].Split('/')[0]
                }
                else {
                    throw "Subnet ID missing from NIC"
                }
            }
            catch {
                $ErrorInfo = $_.Exception.Message

                Write-Warning "${VMName}: $ErrorInfo"
            }

            [PSCustomObject]@{
                Subscription          = $Context.Subscription.Name
                HostPool              = $Pool.Name
                HostPoolResourceGroup = $PoolRG
                VMName                = $VMName
                VMResourceGroup       = $VMRG
                PrivateIP             = $IP
                VMSize                = $VMSize
                VNet                  = $VNet
                Subnet                = $Subnet
                PowerState            = $PowerState
                AVDStatus             = $HostEntry.Status
                AllowNewSession       = $HostEntry.AllowNewSession
                Sessions              = $HostEntry.Session
                Error                 = $ErrorInfo
            }
        }
    }
)

# Visa resultat
$Results |
    Format-Table HostPool, VMName, VMResourceGroup,
        PrivateIP, VNet, Subnet, PowerState, AVDStatus -AutoSize

# Exportera CSV
$Results |
    Export-Csv `
        -Path $OutputFile `
        -Delimiter ';' `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host "`nCSV: $OutputFile" -ForegroundColor Green
Write-Host "Session hosts: $($Results.Count)"
Write-Host "Errors: $( @($Results | Where-Object Error).Count )"

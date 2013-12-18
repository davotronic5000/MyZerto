#Requires -Version 3
#Requires -PSSnapin "VMware.VimAutomation.Core"
#Requires -PSSnapin "Zerto.PS.Commands"

#region Enable-HostMaintenance
<# 
.SYNOPSIS
Enables VM Hosts holding Zerto VM replicas to be placed in to maintenance mode safely.

.DESCRIPTION
Enlists the Zerto powershell cmdlets to move all replicated workloads from a source host to a target host, allowing the host to gracefully enter VMware maintenance mode without
affecting Zerto replications. 

.PARAMETER  ZvmIP
THe IP address for the Zerto Virtual Manager server

.PARAMETER ZvmPort
The port used to connect to the Zerto virtual manager server the default is 9080, the default port for the Zerto API

.PARAMETER SourceVMHost
THe name of the host in vCenter the VMs are currently being replicated to

.PARAMETER TargetVMHost
The name of the host in vCenter you would like the VMs to be replicated to

.PARAMETER Credential
Credentials to use if the Zerto API has been configured to use authentication.  Accepts PSCredential objects.

.PARAMETER EnterVMwareMaintenanceMode
Sets the option to put the VMware host in to maintenance mode as part of the process, this will also shut down the Zerto VRAs on the cluster
once all other servers have been migrated off the host.  This process requires DRS to be enabled on the cluster and configured to be fully automated. 

.EXAMPLE
Enable-HostMaintenance -ZvmIP "10.0.0.50" -SourceVMHost "Host2" -TargetVMHost "Host1" -Credential "testuser"
Moves all replicas from Host2 to Host1 with specified credentials

.EXAMPLE
Enable-HostMaintenance -ZvmIP "10.0.0.50" -SourceVMHost "Host1" -TargetHost "Host2"
Moves all replicas from Host1 to Host2

.Example
Enable-HostMaintenance -ZvmIP "10.0.0.50" -SourceVMHost "Host1" -TargetHost "Host2" -EnterVMwareMaintenanceMode
Moves all replicas from Host1 to Host2 and puts the host in to maintenance mode

.INPUTS
None

.OUTPUTS
None

.NOTES
The EnterVMwareMaintenanceMode switch requires a connection to the vCenter server managing the host to be maintained eg: Connect-ViServer "srv-vc01"
.LINK

#>

FUNCTION Enable-HostMaintenance
    {
    [CmdletBinding(ConfirmImpact="Medium")]

    PARAM
        (
        [PARAMETER(Mandatory=$True)]
        [IPADDRESS]$ZvmIP,
       
        [ValidateNotNullOrEmpty()]
        [PSDefaultValue(Help = '9080 - Default Zerto API port')]
        [UINT16]$ZvmPort = 9080,

        [PARAMETER(Mandatory=$True)]
        [STRING]$SourceVMHost,

        [PARAMETER(Mandatory=$True)]
        [STRING]$TargetVMHost,

        [SWITCH]$EnterVMwareMaintenanceMode,

      	[System.Management.Automation.PSCredential]
        [ValidateNotNullOrEmpty()]
      	[System.Management.Automation.Credential()]$Credential =  [System.Management.Automation.PSCredential]::Empty
        )

    #Create basic param arguments
    #Include an incorrect username and password as the Zerto cmdlets have the username and password
    #set as required even if auth is not enabled on the API and the credentials are not even checked.
    $args = @{
    "ZVMIP" = $ZvmIP;
    "ZVMPort" = $ZvmPort;
    "UserName" = "DummyUsername";
    "Password" = "WhyDoesThisMakeMeGiveAPassword";
    }

    #If specific credentials have been supplied then swap out the username and password for proper credentials
    IF (($PSBoundParameters.Credential))
        {
        $args.UserName = $Credential.UserName
        $args.Password = $Credential.GetNetworkCredential().Password
        }

    Write-Verbose "Getting a list of all VMs currently being replicated to $SourceVMHost"
        TRY
            {
            $WorkloadsToMove = Get-GetVmsReplicatingToHost @args -HostIp $SourceVMHost
            }
        CATCH
            {
            Write-Warning "Unable to find any workloads on $SourceVMHost. Exception: $_.Exception.Message"
            }

    IF ($WorkloadsToMove)
        {
        Write-Verbose "Moving Workloads to $TargetVMHost"
        $i = 1
        FOREACH ($Workload in $WorkloadsToMove)
            {
            Write-Verbose "Moving $Workload from $SourceVMHost to $TargetVMHost"
            Write-Progress -Activity "Moving $Workload" -Id 10 -PercentComplete ($i/$($WorkloadsToMove.Count)*100)
            TRY
                {
                Set-ChangeRecoveryHost @args -VmName $Workload -CurrentTargetHost $SourceVMHost -NewTargetHost $TargetVMHost | Out-Null
                }
            CATCH
                {
                Write-Warning "Unable to move $Workload from $SourceVMHost to $TargetVMHost. Exception: $_.Exception.Message"
                }
            $i++
            }
        Write-Progress -Activity "Finished" -Id 10 -PercentComplete 100
        }
    IF ($EnterVMwareMaintenanceMode)
        {
        Write-Verbose "Setting $SourceVMHost to enter Maintenance Mode"
        TRY
            {
            $MaintenanceModeTask = Set-VMHost -VMHost $SourceVMHost -State Maintenance -RunAsync
            $EnteringMaintenanceMode = $True
            }
        CATCH
            {
            Write-Warning "Unable to Set $SourceVMHost in to VMware Maintenance Mode Exception: $_.Exception.Message"
            $EnteringMaintenanceMode = $false
            }

        IF ($EnteringMaintenanceMode)
            {
            DO
                {
                Write-Verbose "Waiting for All VMs to migrate off $SourceVMHost, there are $($VMsOnHost.Count) remaining"
                TRY
                    {
                    $VMsOnHOst = Get-VMHost $SourceVMHost | Get-VM | Where {$_.Name -notmatch "^Z\-(?:VRA|VRAH)\-[0-9]{1,6}$"}
                    Start-Sleep -Seconds 10
                    }
                CATCH
                    {
                    Write-Warning "Unable to retrieve list of VMs on $SourceVMHost. Exception: $_.Exception.Message"
                    }
                }
            WHILE ($VMsOnHOst)

            Write-Verbose "Sutting down Zerto VRAs on $SourceVMHost"
            TRY
                {
                Get-VMHost $SourceVMHost | Get-VM | Where {$_.Name -match "^Z\-(?:VRA|VRAH)\-[0-9]{1,6}$"} | Shutdown-VMGuest -Confirm:$false | Out-Null
                }
            CATCH
                {
                Write-Warning "Unable to shutdown the Zerto VRAs Exception: $_.Exception.Message"
                }
            }
        }
    
    }
#endregion

#region Optimize-Workloads
<# 
.SYNOPSIS
Rebalances Zerto replication workloads accross the target cluster.

.DESCRIPTION
Enlists the Zerto cmdlets to rebalance the replications accross the target cluster in a round-robin fasion.  Usefull after host maintenance to adding additional hosts to a cluster.

.PARAMETER  ZvmIP
THe IP address for the Zerto Virtual Manager server

.PARAMETER ZvmPort
The port used to connect to the Zerto virtual manager server the default is 9080, the default port for the Zerto API

.PARAMETER ProtectingCluster
The VMware cluster containing the hosts to hold the replica VMs

.PARAMETER Credential
Credentials to use if the Zerto API has been configured to use authentication.  Accepts PSCredential objects.

.EXAMPLE
Optimize-Workloads -ZvmIP "10.0.0.50" -ProtectingCluster "Cluster-A" -Credential "TestUser"
Balances protected workloads accross cluster Cluster-A with specified credentials

.EXAMPLE 
Optimize-Workloads -ZvmIP "10.0.0.50" -ProtectingCluster "Cluster-A"
Balances protected workloads accross cluster Cluster-A

.INPUTS
None

.OUTPUTS
None

.NOTES
Requires a connection to the vCenter server managing the cluster to be optimized eg: Connect-ViServer "srv-vc01"

.LINK

#>
FUNCTION Optimize-Workloads
    {
    [CmdletBinding()]

    PARAM
        (
        [PARAMETER(Mandatory=$True)]
        [IPADDRESS]$ZvmIP,

        [ValidateNotNullOrEmpty()]
        [PSDefaultValue(Help = '9080 - Default Zerto API port')]
        [UINT16]$ZvmPort = 9080,

        [PARAMETER(Mandatory=$True)]
        [STRING]$ProtectingCluster,

      	[System.Management.Automation.PSCredential]
        [ValidateNotNullOrEmpty()]
      	[System.Management.Automation.Credential()]$Credential =  [System.Management.Automation.PSCredential]::Empty
        )

            #Create basic param arguments
    #Include an incorrect username and password as the Zerto cmdlets have the username and password
    #set as required even if auth is not enabled on the API and the credentials are not even checked.
    $args = @{
    "ZVMIP" = $ZvmIP
    "ZVMPort" = $ZvmPort
    "UserName" = "DummyUsername"
    "Password" = "WhyDoesThisMakeMeGiveAPassword"
    }

    #If specific credentials have been supplied then swap out the username and password for proper credentials
    IF (($PSBoundParameters.Credential))
        {
        $args.UserName = $Credential.UserName
        $args.Password = $Credential.GetNetworkCredential().Password
        }

    Write-Verbose "Querying vCenter for valid Hosts in $ProtectingCluster"
    TRY
        {
        $VMHosts = Get-Cluster $ProtectingCluster -ErrorAction Stop | Get-VMHost -State Connected -ErrorAction Stop
        }
    CATCH
        {
        Write-Warning "Unable to retrieve hosts in $ProtectingCluster Exception: $_.Exception.Message"
        }
    IF ($VMHosts)
            {
        Write-Verbose "Querying Zerto for all Workloads to Prottect on $ProtectingCluster and creating a custom array to map Workload to protecting host"
        $WorkloadsToOptimize = FOREACH ($VMHost in $VMhosts)
            {
            $workloads = $null
            TRY
                {
                $Workloads = Get-GetVmsReplicatingToHost @Args -HostIp $VMHost.Name -ErrorAction Stop
                }
            CATCH
                {
                Write-Warning "No Workloads found on $VMHost Exception: $_.Exception.Message"
                }
                IF ($Workloads)
                    {
                    FOREACH ($Workload in $Workloads)
                        {
                        [PSCustomObject]@{
                        "ProtectingHost" = $VMHost
                        "Workload" = $Workload
                        }
                        }
                    }
            }

        Write-Verbose "Balancing workloads accross $ProtectingCluster"
        #setting up for round robin of VMHost Array
        #initialising count variable
        $i = 0 
        $progress = 1
        #getting length of aray
        $max = $VMHosts.Count
        FOREACH ($Workload in $WorkloadsToOptimize)
            {
            #Reset the count variable if it goes past the end of the array
            IF ($i -ge $max)
                {
                $i = 0
                }
            IF ($Workload.ProtectingHost -ne $VMHosts[$i])
                {
                Write-Verbose "Moving protection of $($Workload.Workload) to $($VMHosts[$i])"
                Write-Progress -Activity "Moving protection of $($Workload.Workload) to $($VMHosts[$i])" -Id 20 -PercentComplete ($progress/$($WorkloadsToOptimize.Count)*100)
                TRY
                    {
                    Set-ChangeRecoveryHost @args -VmName $($Workload.Workload) -CurrentTargetHost $($Workload.ProtectingHost) -NewTargetHost $($VMHosts[$i]) | Out-Null
                    }
                CATCH
                    {
                    Write-Warning "Unable to move $($Workload.Workload) from $($Workload.ProtectingHost) to $($VMhosts[$i]). Exception: $_.Exception.Message"
                    }
                }
            ELSE
                {
                Write-Verbose "$($Workload.Workload) is already being protected by $($VMHosts[$i])"
                }
        
            #increment counter by 1
            $progress++
            $i++
            }
        }
    }
#endregion
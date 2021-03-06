configuration ConfigureSQLVM
{
    param
    (
        [Parameter(Mandatory)] [String]$DNSServer,
        [Parameter(Mandatory)] [String]$DomainFQDN,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$DomainAdminCreds,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$SqlSvcCreds,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$SPSetupCreds
    )

    Import-DscResource -ModuleName ComputerManagementDsc, NetworkingDsc, ActiveDirectoryDsc, SqlServerDsc, xPSDesiredStateConfiguration

    WaitForSqlSetup
    [String] $DomainNetbiosName = (Get-NetBIOSName -DomainFQDN $DomainFQDN)
    $Interface = Get-NetAdapter| Where-Object Name -Like "Ethernet*"| Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)
    [PSCredential] $DomainAdminCredsQualified = New-Object PSCredential ("${DomainNetbiosName}\$($DomainAdminCreds.UserName)", $DomainAdminCreds.Password)
    [PSCredential] $SPSetupCredsQualified = New-Object PSCredential ("${DomainNetbiosName}\$($SPSetupCreds.UserName)", $SPSetupCreds.Password)
    [PSCredential] $SQLCredsQualified = New-Object PSCredential ("${DomainNetbiosName}\$($SqlSvcCreds.UserName)", $SqlSvcCreds.Password)
    $ComputerName = Get-Content env:computername

    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        #**********************************************************
        # Initialization of VM - Do as much work as possible before waiting on AD domain to be available
        #**********************************************************
        WindowsFeature ADTools  { Name = "RSAT-AD-Tools";      Ensure = "Present"; }
        WindowsFeature ADPS     { Name = "RSAT-AD-PowerShell"; Ensure = "Present"; }
        
        DnsServerAddress SetDNS { Address = $DNSServer; InterfaceAlias = $InterfaceAlias; AddressFamily  = 'IPv4' }
        
        SqlMaxDop ConfigureMaxDOP { ServerName = $ComputerName; InstanceName = "MSSQLSERVER"; MaxDop = 1; }

        #**********************************************************
        # Join AD forest
        #**********************************************************
        # If WaitForADDomain does not find the domain whtin "WaitTimeout" secs, it will signar a restart to DSC engine "RestartCount" times
        WaitForADDomain DscForestWait
        {
            DomainName              = $DomainFQDN
            WaitTimeout             = 1200
            RestartCount            = 2
            WaitForValidCredentials = $True
            Credential              = $DomainAdminCredsQualified
            DependsOn               = "[DnsServerAddress]SetDNS"
        }

        # WaitForADDomain sets reboot signal only if WaitForADDomain did not find domain within "WaitTimeout" secs
        PendingReboot RebootOnWaitForADDomainSignal
        {
            Name             = "RebootOnWaitForADDomainSignal"
            SkipCcmClientSDK = $true
            DependsOn        = "[WaitForADDomain]DscForestWait"
        }

        Computer DomainJoin
        {
            Name       = $ComputerName
            DomainName = $DomainFQDN
            Credential = $DomainAdminCredsQualified
            DependsOn  = "[PendingReboot]RebootOnWaitForADDomainSignal"
        }

        PendingReboot RebootOnComputerSignal
        {
            Name             = "RebootOnComputerSignal"
            SkipCcmClientSDK = $true
            DependsOn        = "[Computer]DomainJoin"
        }

        #**********************************************************
        # Create accounts and configure SQL Server
        #**********************************************************
        ADUser CreateSqlSvcAccount
        {
            DomainName           = $DomainFQDN
            UserName             = $SqlSvcCreds.UserName
            Password             = $SQLCredsQualified
            PasswordNeverExpires = $true
            Ensure               = "Present"
            PsDscRunAsCredential = $DomainAdminCredsQualified
            DependsOn            = "[PendingReboot]RebootOnComputerSignal"
        }

        ADServicePrincipalName SqlSvcSPN1
        {
            ServicePrincipalName = "MSSQLSvc/$ComputerName.$($DomainFQDN):1433"
            Account              = $SqlSvcCreds.UserName
            PsDscRunAsCredential = $DomainAdminCredsQualified
            Ensure               = "Present"
            DependsOn            = "[ADUser]CreateSqlSvcAccount"
        }

        ADServicePrincipalName SqlSvcSPN2
        {
            ServicePrincipalName = "MSSQLSvc/$ComputerName.$DomainFQDN"
            Account              = $SqlSvcCreds.UserName
            PsDscRunAsCredential = $DomainAdminCredsQualified
            Ensure               = "Present"
            DependsOn            = "[ADUser]CreateSqlSvcAccount"
        }

        ADServicePrincipalName SqlSvcSPN3
        {
            ServicePrincipalName = "MSSQLSvc/$($ComputerName):1433"
            Account              = $SqlSvcCreds.UserName
            PsDscRunAsCredential = $DomainAdminCredsQualified
            Ensure               = "Present"
            DependsOn            = "[ADUser]CreateSqlSvcAccount"
        }

        ADServicePrincipalName SqlSvcSPN4
        {
            ServicePrincipalName = "MSSQLSvc/$ComputerName"
            Account              = $SqlSvcCreds.UserName
            PsDscRunAsCredential = $DomainAdminCredsQualified
            Ensure               = "Present"
            DependsOn            = "[ADUser]CreateSqlSvcAccount"
        }

        SqlServiceAccount SetSqlInstanceServiceAccount
        {
            ServerName     = $ComputerName
            InstanceName   = "MSSQLSERVER"
            ServiceType    = "DatabaseEngine"
            ServiceAccount = $SQLCredsQualified
            RestartService = $true
            DependsOn      = "[ADServicePrincipalName]SqlSvcSPN1", "[ADServicePrincipalName]SqlSvcSPN2", "[ADServicePrincipalName]SqlSvcSPN3", "[ADServicePrincipalName]SqlSvcSPN4"
        }

        SqlLogin AddDomainAdminLogin
        {
            Name         = "${DomainNetbiosName}\$($DomainAdminCreds.UserName)"
            Ensure       = "Present"
            ServerName   = $ComputerName
            InstanceName = "MSSQLSERVER"
            LoginType    = "WindowsUser"
            DependsOn    = "[PendingReboot]RebootOnComputerSignal"
        }

        ADUser CreateSPSetupAccount
        {
            DomainName           = $DomainFQDN
            UserName             = $SPSetupCreds.UserName
            Password             = $SPSetupCredsQualified
            PasswordNeverExpires = $true
            PsDscRunAsCredential = $DomainAdminCredsQualified
            Ensure               = "Present"
            DependsOn            = "[PendingReboot]RebootOnComputerSignal"
        }

        SqlLogin AddSPSetupLogin
        {
            Name         = "${DomainNetbiosName}\$($SPSetupCreds.UserName)"
            Ensure       = "Present"
            ServerName   = $ComputerName
            InstanceName = "MSSQLSERVER"
            LoginType    = "WindowsUser"
            DependsOn    = "[ADUser]CreateSPSetupAccount"
        }

        SqlRole GrantSQLRoleSysadmin
        {
            ServerRoleName   = "sysadmin"
            MembersToInclude = "${DomainNetbiosName}\$($DomainAdminCreds.UserName)"
            ServerName       = $ComputerName
            InstanceName     = "MSSQLSERVER"
            Ensure           = "Present"
            DependsOn        = "[SqlLogin]AddDomainAdminLogin"
        }

        SqlRole GrantSQLRoleSecurityAdmin
        {
            ServerRoleName   = "securityadmin"
            MembersToInclude = "${DomainNetbiosName}\$($SPSetupCreds.UserName)"
            ServerName       = $ComputerName
            InstanceName     = "MSSQLSERVER"
            Ensure           = "Present"
            DependsOn        = "[SqlLogin]AddSPSetupLogin"
        }

        SqlRole GrantSQLRoleDBCreator
        {
            ServerRoleName   = "dbcreator"
            MembersToInclude = "${DomainNetbiosName}\$($SPSetupCreds.UserName)"
            ServerName       = $ComputerName
            InstanceName     = "MSSQLSERVER"
            Ensure           = "Present"
            DependsOn        = "[SqlLogin]AddSPSetupLogin"
        }

        # Open port on the firewall only when everything is ready, as SharePoint DSC is testing it to start creating the farm
        Firewall DatabaseEngineFirewallRule
        {
            Direction   = "Inbound"
            Name        = "SQL-Server-Database-Engine-TCP-In"
            DisplayName = "SQL Server Database Engine (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Engine."
            Group       = "SQL Server"
            Enabled     = "True"
            Protocol    = "TCP"
            LocalPort   = "1433"
            Ensure      = "Present"
        }
    }
}

function Get-NetBIOSName
{
    [OutputType([string])]
    param(
        [string]$DomainFQDN
    )

    if ($DomainFQDN.Contains('.')) {
        $length=$DomainFQDN.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainFQDN.Substring(0,$length)
    }
    else {
        if ($DomainFQDN.Length -gt 15) {
            return $DomainFQDN.Substring(0,15)
        }
        else {
            return $DomainFQDN
        }
    }
}

function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}



<#
# Azure DSC extension logging: C:\WindowsAzure\Logs\Plugins\Microsoft.Powershell.DSC\2.21.0.0
# Azure DSC extension configuration: C:\Packages\Plugins\Microsoft.Powershell.DSC\2.21.0.0\DSCWork
Install-Module -Name SqlServerDsc

help ConfigureSQLVM
$DomainAdminCreds = Get-Credential -Credential "yvand"
$SqlSvcCreds = Get-Credential -Credential "sqlsvc"
$SPSetupCreds = Get-Credential -Credential "spsetup"
$DNSServer = "10.1.1.4"
$DomainFQDN = "contoso.local"

$outputPath = "C:\Packages\Plugins\Microsoft.Powershell.DSC\2.80.0.3\DSCWork\ConfigureSQLVM.0\ConfigureSQLVM"
ConfigureSQLVM -DNSServer $DNSServer -DomainFQDN $DomainFQDN -DomainAdminCreds $DomainAdminCreds -SqlSvcCreds $SqlSvcCreds -SPSetupCreds $SPSetupCreds -ConfigurationData @{AllNodes=@(@{ NodeName="localhost"; PSDscAllowPlainTextPassword=$true })} -OutputPath $outputPath
Start-DscConfiguration -Path $outputPath -Wait -Verbose -Force

#>

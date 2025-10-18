# Password Expiry Checker v6 - Simple HTML Report Format
# Enhanced version: reads SMTP credentials from environment variables if not passed

param(
    [int]$WarningDays = 50,  # Number of days before expiry to start warning
    [string]$SMTPServer = "smtp.office365.com",
    [int]$SMTPPort = 587,
    [string]$From = "ticket@taashee.com",
    [string]$To = "internalapollo@taashee.com",
    [string]$smtpUser,
    [string]$smtpPassword,
    [string]$Subject = "Password Expiry Warning",
    [string]$LogPath = "C:\Scripts\Logs\PasswordExpiry.log",
    [switch]$CheckDomainUsers = $true,
    [switch]$CheckLocalUsers = $true,
    [string]$AdminSignature = "Apollo ProProtect Admin"
)

# --- Fallbacks from environment variables ---
if (-not $smtpUser -and $env:SMTP_USER) { $smtpUser = $env:SMTP_USER }
if (-not $smtpPassword -and $env:SMTP_PASSWORD) { $smtpPassword = $env:SMTP_PASSWORD }

# --- Validate that SMTP credentials exist ---
if (-not $smtpUser -or -not $smtpPassword) {
    Write-Error "SMTP credentials are missing. Provide -SMTPUsername and -SMTPPassword or set SMTP_USER / SMTP_PASSWORD environment variables."
    exit 1
}

# Force TLS 1.2 for Office 365 compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to write to log file
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Write-Host $logMessage
    Add-Content -Path $LogPath -Value $logMessage
}

# Function to get server IP address
function Get-ServerIP {
    try {
        $networkConfig = Get-WmiObject -Class Win32_NetworkAdapterConfiguration | Where-Object {$_.IPEnabled -eq $true -and $_.IPAddress -ne $null}
        $ipAddress = $networkConfig | Where-Object {$_.IPAddress[0] -notlike "169.254.*" -and $_.IPAddress[0] -notlike "127.*"} | Select-Object -First 1
        return $ipAddress.IPAddress[0]
    }
    catch {
        return "Unknown"
    }
}

# Function to check if server is domain controller
function Test-IsDomainController {
    try {
        $role = Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty ProductType
        return $role -eq 2  # 2 = Domain Controller
    }
    catch {
        return $false
    }
}

# Function to get domain password policy using NET ACCOUNTS
function Get-DomainPasswordPolicy {
    try {
        $netAccounts = net accounts /domain 2>$null
        if ($LASTEXITCODE -eq 0) {
            $maxPasswordAge = $netAccounts | Where-Object {$_ -match "Maximum password age"} | ForEach-Object {
                if ($_ -match "(\d+)") {
                    return [int]$matches[1]
                }
            }
            return $maxPasswordAge
        }
        else {
            # If domain command fails, try local
            $netAccounts = net accounts 2>$null
            $maxPasswordAge = $netAccounts | Where-Object {$_ -match "Maximum password age"} | ForEach-Object {
                if ($_ -match "(\d+)") {
                    return [int]$matches[1]
                }
            }
            return $maxPasswordAge
        }
    }
    catch {
        return 42  # Default to 42 days if unable to determine
    }
}

# Function to get domain users using NET USER
function Get-DomainUsers {
    try {
        $users = @()
        $netUsers = net user /domain 2>$null
        if ($LASTEXITCODE -eq 0) {
            $userLines = $netUsers | Select-Object -Skip 4 | Where-Object {$_ -match "\S+" -and $_ -notmatch "The command completed successfully"}
            
            foreach ($line in $userLines) {
                $usernames = $line -split '\s+' | Where-Object {$_ -ne ""}
                foreach ($username in $usernames) {
                    if ($username -and $username -ne "") {
                        try {
                            $userInfo = net user $username /domain 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                $user = Parse-NetUserOutput -UserInfo $userInfo -Username $username -IsDomain $true
                                if ($user) {
                                    $users += $user
                                }
                            }
                        }
                        catch {
                            Write-Log "Error getting info for domain user: $username"
                        }
                    }
                }
            }
        }
        return $users
    }
    catch {
        Write-Log "Error getting domain users: $($_.Exception.Message)"
        return @()
    }
}

# Function to get local users
function Get-LocalUsers {
    try {
        $users = @()
        $localUsers = Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount=True"
        
        foreach ($localUser in $localUsers) {
            if ($localUser.Disabled -eq $false) {
                try {
                    $userInfo = net user $localUser.Name 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $user = Parse-NetUserOutput -UserInfo $userInfo -Username $localUser.Name -IsDomain $false
                        if ($user) {
                            $users += $user
                        }
                    }
                }
                catch {
                    Write-Log "Error getting info for local user: $($localUser.Name)"
                }
            }
        }
        return $users
    }
    catch {
        Write-Log "Error getting local users: $($_.Exception.Message)"
        return @()
    }
}

# Function to parse NET USER output
function Parse-NetUserOutput {
    param(
        [string[]]$UserInfo,
        [string]$Username,
        [bool]$IsDomain
    )
    
    try {
        $passwordLastSet = $null
        $passwordExpires = $null
        $accountActive = $true
        $passwordNeverExpires = $false
        
        foreach ($line in $UserInfo) {
            if ($line -match "Password last set\s+(.+)") {
                $passwordLastSetStr = $matches[1].Trim()
                if ($passwordLastSetStr -ne "Never") {
                    try {
                        $passwordLastSet = [DateTime]::Parse($passwordLastSetStr)
                    }
                    catch {
                        $passwordLastSet = $null
                    }
                }
            }
            elseif ($line -match "Password expires\s+(.+)") {
                $passwordExpiresStr = $matches[1].Trim()
                if ($passwordExpiresStr -eq "Never") {
                    $passwordNeverExpires = $true
                }
                else {
                    try {
                        $passwordExpires = [DateTime]::Parse($passwordExpiresStr)
                    }
                    catch {
                        $passwordExpires = $null
                    }
                }
            }
            elseif ($line -match "Account active\s+(.+)") {
                $accountActive = $matches[1].Trim() -eq "Yes"
            }
        }
        
        if ($accountActive -and -not $passwordNeverExpires -and $passwordLastSet) {
            return [PSCustomObject]@{
                Name = $Username
                SamAccountName = $Username
                PasswordLastSet = $passwordLastSet
                PasswordExpires = $passwordExpires
                PasswordNeverExpires = $passwordNeverExpires
                AccountActive = $accountActive
                IsDomain = $IsDomain
            }
        }
        
        return $null
    }
    catch {
        Write-Log "Error parsing user info for $Username`: $($_.Exception.Message)"
        return $null
    }
}

# Function to generate simple HTML email body
function Generate-SimpleHTMLEmailBody {
    param(
        [array]$WarnUsers,
        [string]$ServerName,
        [string]$ServerIP,
        [int]$WarningDays
    )
    
    $body = @"
<html>
<head>
<style>
    table {
        border-collapse: collapse;
        width: 100%;
        font-family: Arial, sans-serif;
    }
    th, td {
        border: 1px solid #dddddd;
        text-align: left;
        padding: 8px;
    }
    th {
        background-color: #f2f2f2;
    }
</style>
</head>
<body>
<p><strong>Password Expiry Alert</strong></p>
<p>The following user accounts on <strong>$ServerName</strong> have passwords expiring in less than $WarningDays days or already expired:</p>
<table>
<tr>
<th>Host</th>
<th>IP Address</th>
<th>Username</th>
<th>Days Until Expiry</th>
</tr>
"@

    foreach ($entry in $WarnUsers) {
        $body += @"
<tr>
<td>$($entry.Hostname)</td>
<td>$($entry.IP)</td>
<td>$($entry.Username)</td>
<td>$($entry.DaysLeft)</td>
</tr>
"@
    }

    $body += @"
</table>
<p>Thanks and Regards,<br/>$AdminSignature</p>
</body>
</html>
"@
    return $body
}

# Function to send HTML email
function Send-HTMLEmailNotification {
    param(
        [string]$HTMLBody,
        [string]$EmailSubject
    )
    
    try {
        $securePassword = ConvertTo-SecureString $smtpPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($smtpUser, $securePassword)
        
        Write-Log "Attempting to send HTML email via $SMTPServer`:$SMTPPort"
        Write-Log "From: $From, To: $To"
        
        Send-MailMessage -To $To -From $From -Subject $EmailSubject -Body $HTMLBody -BodyAsHtml -SmtpServer $SMTPServer -Port $SMTPPort -Credential $credential -UseSsl
        Write-Log "HTML email sent successfully to $To"
    }
    catch {
        Write-Log "Failed to send HTML email: $($_.Exception.Message)"
        $htmlFile = Join-Path (Split-Path $LogPath -Parent) "HTMLEmailBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
        Set-Content -Path $htmlFile -Value $HTMLBody
        Write-Log "HTML email content saved to: $htmlFile"
    }
}

# Main script (unchanged from original)
try {
    $logDir = Split-Path $LogPath -Parent
    if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force }
    
    Write-Log "Starting Password Expiry Check v6..."
    $serverName = $env:COMPUTERNAME
    $serverIP = Get-ServerIP
    $currentDate = Get-Date
    $isDomainController = Test-IsDomainController
    
    Write-Log "Server: $serverName ($serverIP)"
    Write-Log "Is Domain Controller: $isDomainController"
    
    $maxPasswordAge = Get-DomainPasswordPolicy
    Write-Log "Password policy: Maximum password age is $maxPasswordAge days"
    
    $allUsers = @()
    if ($CheckDomainUsers) {
        Write-Log "Checking domain users..."
        $domainUsers = Get-DomainUsers
        $allUsers += $domainUsers
        Write-Log "Found $($domainUsers.Count) domain users"
    }
    if ($CheckLocalUsers) {
        Write-Log "Checking local users..."
        $localUsers = Get-LocalUsers
        $allUsers += $localUsers
        Write-Log "Found $($localUsers.Count) local users"
    }
    
    $warnUsers = @()
    foreach ($user in $allUsers) {
        if ($user.PasswordLastSet) {
            $passwordAge = ($currentDate - $user.PasswordLastSet).Days
            $daysUntilExpiry = $maxPasswordAge - $passwordAge
            if ($daysUntilExpiry -lt $WarningDays -and $daysUntilExpiry -gt 0) {
                $warnUsers += @{ Hostname=$serverName; IP=$serverIP; Username=$user.Name; DaysLeft="$daysUntilExpiry days" }
            } elseif ($daysUntilExpiry -le 0) {
                $warnUsers += @{ Hostname=$serverName; IP=$serverIP; Username=$user.Name; DaysLeft="EXPIRED" }
            }
        }
    }
    
    if ($warnUsers.Count -gt 0) {
        $htmlEmailBody = Generate-SimpleHTMLEmailBody -WarnUsers $warnUsers -ServerName $serverName -ServerIP $serverIP -WarningDays $WarningDays
        $emailSubject = "[$serverName] $Subject"
        Send-HTMLEmailNotification -HTMLBody $htmlEmailBody -EmailSubject $emailSubject
        Write-Log "Password expiry warning email sent"
    } else {
        Write-Log "No users with expiring passwords found"
    }
    
    Write-Log "Password expiry check v6 completed successfully"
}
catch {
    Write-Log "Error occurred: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
}

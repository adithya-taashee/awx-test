param (
  [string]$smtpServer = "smtp.office365.com",
  [int]$smtpPort = 587,
  [string]$from = "ticket@taashee.com",
  [string]$to = "adithya.k@taashee.com",
  [string]$smtpUser,
  [string]$smtpPassword
)

# Fallbacks from env vars if not passed:
if (-not $smtpUser -and $env:SMTP_USER) { $smtpUser = $env:SMTP_USER }
if (-not $smtpPassword -and $env:SMTP_PASSWORD) { $smtpPassword = $env:SMTP_PASSWORD }

if (-not $smtpUser -or -not $smtpPassword) {
  Write-Error "SMTP credentials are missing. Provide -smtpUser and -smtpPassword or set SMTP_USER/SMTP_PASSWORD env vars."
  exit 1
}
function Get-LocalUsers {
    Get-LocalUser | Where-Object {
        $_.Enabled -eq $true -and $_.Name -ne "Administrator"
    }
}

function Get-PasswordInfo {
    param([string]$user)

    try {
        $localUser = Get-LocalUser -Name $user -ErrorAction Stop
    } catch {
        return @{ days_left = -1; warning = "unknown" }
    }

    $wmiUser = Get-WmiObject -Class Win32_UserAccount -Filter "Name='$user' AND LocalAccount='True'"
    if ($wmiUser.PasswordExpires -eq $false) {
        return @{ days_left = 9999; warning = "never" }
    }

    $lastSet = $localUser.PasswordLastSet
    if ($lastSet -eq $null) {
        return @{ days_left = -2; warning = "unknown" }
    }

    $maxAge = 42
    $expiryDate = $lastSet.AddDays($maxAge)
    $daysLeft = ($expiryDate - (Get-Date)).Days

    $warn = if ($daysLeft -lt 50) { "yes" } else { "no" }

    return @{ days_left = $daysLeft; warning = $warn }
}

# Main
$users = Get-LocalUsers
$warnUsers = @()
$hostname = $env:COMPUTERNAME

# Get primary IPv4 address (non-loopback)
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike "169.*" -and $_.InterfaceAlias -notlike "*Loopback*" -and $_.PrefixOrigin -ne "WellKnown" } |
       Select-Object -First 1 -ExpandProperty IPAddress)

foreach ($u in $users) {
    $info = Get-PasswordInfo -user $u.Name
    if ($info.warning -eq "yes") {
        $warnUsers += @{
            Hostname  = $hostname
            IP        = $ip
            Username  = $u.Name
            DaysLeft  = "$($info.days_left) days"
        }
    }
}

if ($warnUsers.Count -gt 0) {
    # Build HTML email
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
  <p>The following user accounts on <strong>$hostname</strong> have passwords expiring in less than 50 days:</p>

  <table>
    <tr>
        <th>Host</th>
        <th>IP Address</th>
        <th>Username</th>
        <th>Days Until Expiry</th>
    </tr>
"@

    foreach ($entry in $warnUsers) {
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
  <p>Thanks and Regards,<br/>Apollo ProProtect Admin</p>
</body>
</html>
"@

    # Send email
    Send-MailMessage -SmtpServer $smtpServer -Port $smtpPort `
        -From $from -To $to -Subject "[$hostname] Password Expiry Warning" `
        -Body $body -BodyAsHtml -UseSsl `
        -Credential (New-Object System.Management.Automation.PSCredential($smtpUser, (ConvertTo-SecureString $smtpPassword -AsPlainText -Force)))
}

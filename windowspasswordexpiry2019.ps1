param (
    [string]$smtpUser,
    [string]$smtpPassword
)

# Ensure TLS 1.2 is used
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# SMTP Settings
$SmtpServer = "smtp.office365.com"
$SmtpPort   = 587
$To         = "internalapollo@taashee.com"

# --- Fallbacks from environment variables ---
if (-not $smtpUser -and $env:SMTP_USER) { $smtpUser = $env:SMTP_USER }
if (-not $smtpPassword -and $env:SMTP_PASSWORD) { $smtpPassword = $env:SMTP_PASSWORD }

# --- Check for missing credentials ---
if (-not $smtpUser -or -not $smtpPassword) {
    Write-Error "SMTP credentials are missing. Provide -smtpUser and -smtpPassword or set SMTP_USER/SMTP_PASSWORD env vars."
    exit 1
}

$Username = $smtpUser
$Password = $smtpPassword
$From     = $Username

$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($Username, $SecurePassword)

# =====================================================
# Get ALL local users (enabled, excluding Administrator)
# =====================================================
function Get-LocalUsers {
    Get-LocalUser | Where-Object {
        $_.Enabled -eq $true -and $_.Name -ne "Administrator"
    }
}

# =====================================================
# Get password expiry info (NO FILTERING)
# =====================================================
function Get-PasswordInfo {
    param([string]$user)

    try {
        $localUser = Get-LocalUser -Name $user -ErrorAction Stop
    } catch {
        return @{ days_left = "Unknown" }
    }

    $wmiUser = Get-WmiObject -Class Win32_UserAccount -Filter "Name='$user' AND LocalAccount='True'"

    # Password never expires
    if ($wmiUser.PasswordExpires -eq $false) {
        return @{ days_left = "Never Expires" }
    }

    # Password last set missing
    if ($localUser.PasswordLastSet -eq $null) {
        return @{ days_left = "Unknown" }
    }

    # Local password policy (default 42 days)
    $maxAge = 42
    $expiryDate = $localUser.PasswordLastSet.AddDays($maxAge)
    $daysLeft = ($expiryDate - (Get-Date)).Days

    if ($daysLeft -lt 0) {
        return @{ days_left = "Expired" }
    }
    else {
        return @{ days_left = "$daysLeft days" }
    }
}

# ==========================
# Main Logic
# ==========================
$users = Get-LocalUsers
$reportUsers = @()
$hostname = $env:COMPUTERNAME

# Get IPv4 address (non-loopback)
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "169.*" -and
        $_.InterfaceAlias -notlike "*Loopback*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } |
    Select-Object -First 1 -ExpandProperty IPAddress)

foreach ($u in $users) {
    $info = Get-PasswordInfo -user $u.Name
    $reportUsers += [PSCustomObject]@{
        Hostname = $hostname
        IP       = $ip
        Username = $u.Name
        DaysLeft = $info.days_left
    }
}

# =====================================================
# HTML REPORT (UNCHANGED)
# =====================================================
if ($reportUsers.Count -gt 0) {

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
    <p>The following user accounts on <strong>$hostname</strong> have passwords expiring in less than 50 days or already expired:</p>
    <table>
        <tr>
            <th>Host</th>
            <th>IP Address</th>
            <th>Username</th>
            <th>Days Until Expiry</th>
        </tr>
"@

    foreach ($entry in $reportUsers) {
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

    Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -UseSsl `
        -Credential $Cred -From $From -To $To `
        -Subject "[$hostname] Password Expiry Warning" `
        -Body $body -BodyAsHtml
}

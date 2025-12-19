# Password Expiry Checker v6.1 - FULL USER LIST (Original HTML Format Preserved)

param(
    [int]$WarningDays = 50,
    [string]$SMTPServer = "smtp.office365.com",
    [int]$SMTPPort = 587,
    [string]$From = "ticket@taashee.com",
    [string]$To = "internalapollo@taashee.com",
    [string]$smtpUser,
    [string]$smtpPassword,
    [string]$Subject = "Password Expiry Report",
    [string]$LogPath = "C:\Scripts\Logs\PasswordExpiry.log",
    [switch]$CheckDomainUsers = $true,
    [switch]$CheckLocalUsers = $true,
    [string]$AdminSignature = "Apollo ProProtect Admin"
)

# ================= SMTP FALLBACK =================
if (-not $smtpUser -and $env:SMTP_USER) { $smtpUser = $env:SMTP_USER }
if (-not $smtpPassword -and $env:SMTP_PASSWORD) { $smtpPassword = $env:SMTP_PASSWORD }

if (-not $smtpUser -or -not $smtpPassword) {
    Write-Error "SMTP credentials missing"
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ================= LOG =================
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "$ts - $Message"
    Write-Host "$ts - $Message"
}

# ================= SERVER IP =================
function Get-ServerIP {
    try {
        (Get-WmiObject Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.IPAddress[0] -notlike "169.254*" } |
        Select-Object -First 1).IPAddress[0]
    } catch { "Unknown" }
}

# ================= PASSWORD POLICY =================
function Get-DomainPasswordPolicy {
    $out = net accounts /domain 2>$null
    if ($LASTEXITCODE -ne 0) { $out = net accounts }
    ($out | Where-Object {$_ -match "Maximum password age"} | ForEach-Object {
        [int]($_ -replace '\D','')
    })
}

# ================= NET USER PARSER =================
function Parse-NetUserOutput {
    param(
        [string[]]$UserInfo,
        [string]$Username,
        [bool]$IsDomain
    )

    $pwdLastSet = $null
    $pwdExpires = $null
    $pwdNever = $false
    $active = $true

    foreach ($line in $UserInfo) {
        if ($line -match "Password last set\s+(.+)") {
            if ($matches[1] -ne "Never") {
                $pwdLastSet = [datetime]$matches[1]
            }
        }
        elseif ($line -match "Password expires\s+(.+)") {
            if ($matches[1] -eq "Never") {
                $pwdNever = $true
            } else {
                $pwdExpires = [datetime]$matches[1]
            }
        }
        elseif ($line -match "Account active\s+(.+)") {
            $active = $matches[1].Trim() -eq "Yes"
        }
    }

    if ($active) {
        [PSCustomObject]@{
            Name                 = $Username
            PasswordLastSet      = $pwdLastSet
            PasswordExpires      = $pwdExpires
            PasswordNeverExpires = $pwdNever
            IsDomain             = $IsDomain
        }
    }
}

# ================= DOMAIN USERS =================
function Get-DomainUsers {
    $users = @()
    $out = net user /domain 2>$null
    if ($LASTEXITCODE -eq 0) {
        $names = ($out | Select-Object -Skip 4 |
                 Where-Object {$_ -and $_ -notmatch "completed"}) -split '\s+'
        foreach ($n in $names) {
            $info = net user $n /domain 2>$null
            if ($LASTEXITCODE -eq 0) {
                $users += Parse-NetUserOutput $info $n $true
            }
        }
    }
    $users
}

# ================= LOCAL USERS =================
function Get-LocalUsers {
    $users = @()
    Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True AND Disabled=False" |
    ForEach-Object {
        $info = net user $_.Name 2>$null
        if ($LASTEXITCODE -eq 0) {
            $users += Parse-NetUserOutput $info $_.Name $false
        }
    }
    $users
}

# ================= ORIGINAL HTML FORMAT =================
function Generate-SimpleHTMLEmailBody {
    param(
        [array]$AllUsers,
        [string]$ServerName,
        [string]$ServerIP,
        [int]$MaxPasswordAge
    )

$body = @"
<html>
<head>
<style>
table { border-collapse: collapse; width: 100%; font-family: Arial; }
th, td { border: 1px solid #dddddd; padding: 8px; text-align: left; }
th { background-color: #f2f2f2; }
</style>
</head>
<body>
<p><strong>Password Expiry Report</strong></p>

<table>
<tr>
<th>Host</th>
<th>IP Address</th>
<th>Username</th>
<th>Days Until Expiry</th>
</tr>
"@

foreach ($u in $AllUsers) {

    if ($u.PasswordNeverExpires) {
        $daysLeft = "NEVER EXPIRES"
    }
    elseif ($u.PasswordExpires) {
        if ($u.PasswordExpires -lt (Get-Date)) {
            $daysLeft = "EXPIRED"
        } else {
            $daysLeft = (($u.PasswordExpires - (Get-Date)).Days).ToString() + " days"
        }
    }
    elseif ($u.PasswordLastSet) {
        $age = (Get-Date - $u.PasswordLastSet).Days
        $daysLeft = ($MaxPasswordAge - $age).ToString() + " days"
    }
    else {
        $daysLeft = "UNKNOWN"
    }

$body += @"
<tr>
<td>$ServerName</td>
<td>$ServerIP</td>
<td>$($u.Name)</td>
<td>$daysLeft</td>
</tr>
"@
}

$body += @"
</table>
<p>Thanks and Regards,<br/>$AdminSignature</p>
</body>
</html>
"@
$body
}

# ================= SEND EMAIL =================
function Send-HTMLEmailNotification {
    param($HTMLBody,$EmailSubject)

    $cred = New-Object PSCredential(
        $smtpUser,(ConvertTo-SecureString $smtpPassword -AsPlainText -Force)
    )

    Send-MailMessage -To $To -From $From -Subject $EmailSubject `
        -Body $HTMLBody -BodyAsHtml `
        -SmtpServer $SMTPServer -Port $SMTPPort `
        -Credential $cred -UseSsl
}

# ================= MAIN =================
$logDir = Split-Path $LogPath -Parent
if (!(Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force }

Write-Log "Password expiry report started"

$server = $env:COMPUTERNAME
$ip = Get-ServerIP
$maxAge = Get-DomainPasswordPolicy

$users = @()
if ($CheckDomainUsers) { $users += Get-DomainUsers }
if ($CheckLocalUsers) { $users += Get-LocalUsers }

$html = Generate-SimpleHTMLEmailBody `
    -AllUsers $users `
    -ServerName $server `
    -ServerIP $ip `
    -MaxPasswordAge $maxAge

Send-HTMLEmailNotification `
    -HTMLBody $html `
    -EmailSubject "[$server] $Subject"

Write-Log "Password expiry report completed"

# ==========================================================
# Password Expiry Report v7 - Full User Listing (HTML)
# Compatible with Windows Server 2012 R2
# ==========================================================

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

# ================= SMTP ENV FALLBACK =================
if (-not $smtpUser -and $env:SMTP_USER) { $smtpUser = $env:SMTP_USER }
if (-not $smtpPassword -and $env:SMTP_PASSWORD) { $smtpPassword = $env:SMTP_PASSWORD }

if (-not $smtpUser -or -not $smtpPassword) {
    Write-Error "SMTP credentials missing"
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ================= LOG FUNCTION =================
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
    param([string[]]$UserInfo,[string]$Username,[bool]$IsDomain)

    $pwdLastSet = $null
    $pwdExpires = $null
    $pwdNever = $false
    $active = $true

    foreach ($l in $UserInfo) {
        if ($l -match "Password last set\s+(.+)") {
            if ($matches[1] -ne "Never") { $pwdLastSet = [datetime]$matches[1] }
        }
        elseif ($l -match "Password expires\s+(.+)") {
            if ($matches[1] -eq "Never") { $pwdNever = $true }
            else { $pwdExpires = [datetime]$matches[1] }
        }
        elseif ($l -match "Account active\s+(.+)") {
            $active = $matches[1].Trim() -eq "Yes"
        }
    }

    if ($active) {
        [PSCustomObject]@{
            Name                  = $Username
            PasswordLastSet       = $pwdLastSet
            PasswordExpires       = $pwdExpires
            PasswordNeverExpires  = $pwdNever
            IsDomain              = $IsDomain
        }
    }
}

# ================= DOMAIN USERS =================
function Get-DomainUsers {
    $users = @()
    $out = net user /domain 2>$null
    if ($LASTEXITCODE -eq 0) {
        $names = ($out | Select-Object -Skip 4 | Where-Object {$_ -and $_ -notmatch "completed"} ) -split '\s+'
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

# ================= FULL HTML REPORT =================
function Generate-HTMLReport {
    param($Users,$Server,$IP)

$body = @"
<html><style>
table{border-collapse:collapse;font-family:Arial}
th,td{border:1px solid #ccc;padding:6px}
th{background:#f2f2f2}
</style>
<body>
<h3>Password Expiry Report - $Server ($IP)</h3>
<table>
<tr><th>User</th><th>Type</th><th>Password Last Set</th><th>Expiry</th><th>Status</th></tr>
"@

foreach ($u in $Users) {
    if ($u.PasswordNeverExpires) {
        $exp="Never"; $status="Never Expires"
    } elseif ($u.PasswordExpires) {
        $exp=$u.PasswordExpires
        $status= if ($u.PasswordExpires -lt (Get-Date)) { "Expired" }
                 else { "Expires in $(( $u.PasswordExpires-(Get-Date)).Days) days" }
    } else {
        $exp="Unknown"; $status="Unknown"
    }

    $type = if ($u.IsDomain) { "Domain" } else { "Local" }

$body += "<tr><td>$($u.Name)</td><td>$type</td><td>$($u.PasswordLastSet)</td><td>$exp</td><td>$status</td></tr>"
}

$body += "</table><br/>Regards,<br/>$AdminSignature</body></html>"
$body
}

# ================= SEND EMAIL =================
function Send-Mail {
    param($Body,$Subj)
    $cred = New-Object PSCredential($smtpUser,(ConvertTo-SecureString $smtpPassword -AsPlainText -Force))
    Send-MailMessage -To $To -From $From -Subject $Subj -Body $Body -BodyAsHtml `
        -SmtpServer $SMTPServer -Port $SMTPPort -Credential $cred -UseSsl
}

# ================= MAIN =================
$logDir = Split-Path $LogPath -Parent
if (!(Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force }

Write-Log "Password Expiry Report Started"

$server = $env:COMPUTERNAME
$ip = Get-ServerIP
$users = @()

if ($CheckDomainUsers) { $users += Get-DomainUsers }
if ($CheckLocalUsers) { $users += Get-LocalUsers }

$html = Generate-HTMLReport $users $server $ip
Send-Mail $html "[$server] $Subject"

Write-Log "Password Expiry Report Completed"


# Remote deployment helper for Windows users.
# Copies the project to your DigitalOcean Droplet over SSH and runs setup.sh.
# Requirements: Windows 10 / 11 with the built-in OpenSSH client (ssh + scp).
# Usage: .\setup.ps1

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# .env helpers
# ---------------------------------------------------------------------------
function Get-EnvValue {
    param([string]$Key, [string]$EnvFile)
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($null -eq $line) { return '' }
    return ($line -split '=', 2)[1]
}

function Set-EnvValue {
    param([string]$Key, [string]$Value, [string]$EnvFile)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    # Read as raw bytes to avoid PowerShell re-encoding an existing BOM as Latin-1 garbage.
    $bytes = [System.IO.File]::ReadAllBytes($EnvFile)
    # Strip UTF-8 BOM if present (EF BB BF).
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Normalise to LF.
    $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
    # Replace the matching key=value line using a simple line-by-line loop.
    # Avoids [regex]::Replace whose replacement string interprets $n and ${name}
    # as backreferences, which can corrupt content when values contain $ or \.
    $lines = $content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cmatch "^$([regex]::Escape($Key))=") {
            $lines[$i] = "$Key=$Value"
        }
    }
    [System.IO.File]::WriteAllText($EnvFile, ($lines -join "`n"), $utf8NoBom)
}

function New-RandomPassword {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Prompt the user to confirm or replace a single .env value.
# IsSecret: hides the existing value and offers auto-generate for empty fields.
function Invoke-EnvPrompt {
    param(
        [string]$Key,
        [string]$Label,
        [string]$EnvFile,
        [switch]$IsSecret
    )

    $current = Get-EnvValue -Key $Key -EnvFile $EnvFile

    if ($IsSecret) {
        if ([string]::IsNullOrWhiteSpace($current)) {
            $promptText = "$Label (leave blank to auto-generate)"
        } else {
            $promptText = "$Label (leave blank to keep existing)"
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $promptText = "$Label [$current]"
        } else {
            $promptText = $Label
        }
    }

    $input = Read-Host "  $promptText"

    if (-not [string]::IsNullOrWhiteSpace($input)) {
        Set-EnvValue -Key $Key -Value $input -EnvFile $EnvFile
    }
}

# Walk through every .env field interactively.
function Invoke-EnvSetup {
    param([string]$EnvFile)

    Write-Host ""
    Write-Host "Please confirm or update each setting below." -ForegroundColor Yellow
    Write-Host "Press Enter to accept the value shown in brackets." -ForegroundColor Yellow
    Write-Host ""

    Invoke-EnvPrompt -Key 'DOMAIN'                      -Label 'Domain name or server IP (IP will be converted to sslip.io for HTTPS)' -EnvFile $EnvFile
    Invoke-EnvPrompt -Key 'LANGFLOW_SUPERUSER'           -Label 'Langflow admin username'   -EnvFile $EnvFile
    Invoke-EnvPrompt -Key 'LANGFLOW_SUPERUSER_PASSWORD'  -Label 'Langflow admin password'   -EnvFile $EnvFile -IsSecret
    Invoke-EnvPrompt -Key 'POSTGRES_USER'                -Label 'PostgreSQL username'        -EnvFile $EnvFile
    Invoke-EnvPrompt -Key 'POSTGRES_PASSWORD'            -Label 'PostgreSQL password'        -EnvFile $EnvFile -IsSecret
    Invoke-EnvPrompt -Key 'POSTGRES_DB'                  -Label 'PostgreSQL database name'   -EnvFile $EnvFile
    Invoke-EnvPrompt -Key 'LANGFLOW_VERSION'             -Label 'Langflow version tag'       -EnvFile $EnvFile

    Write-Host ""
}

# ---------------------------------------------------------------------------
# Check OpenSSH client is available
# ---------------------------------------------------------------------------
Write-Info "Checking for OpenSSH client..."
if (-not (Get-Command ssh  -ErrorAction SilentlyContinue) -or
    -not (Get-Command scp  -ErrorAction SilentlyContinue)) {
    Write-Err "ssh and scp are required but were not found."
    Write-Err "Enable the OpenSSH Client optional feature:"
    Write-Err "  Settings > System > Optional features > Add a feature > OpenSSH Client"
    exit 1
}
Write-Info "OpenSSH client found."

# ---------------------------------------------------------------------------
# Configure .env
# ---------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
$EnvFile   = Join-Path $ScriptDir '.env'

if (-not (Test-Path $EnvFile)) {
    $ExampleFile = Join-Path $ScriptDir '.env.example'
    if (-not (Test-Path $ExampleFile)) {
        Write-Err ".env.example not found. Run this script from the repo directory."
        exit 1
    }
    Copy-Item $ExampleFile $EnvFile
    # Normalise to LF + no BOM using raw bytes, consistent with Set-EnvValue.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $initBytes = [System.IO.File]::ReadAllBytes($EnvFile)
    if ($initBytes.Length -ge 3 -and $initBytes[0] -eq 0xEF -and $initBytes[1] -eq 0xBB -and $initBytes[2] -eq 0xBF) {
        $initBytes = $initBytes[3..($initBytes.Length - 1)]
    }
    $initRaw = [System.Text.Encoding]::UTF8.GetString($initBytes) -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($EnvFile, $initRaw, $utf8NoBom)
    Write-Info "Created .env from .env.example."
}

# Run interactive setup whenever the domain is still the placeholder.
if ((Get-Content $EnvFile -Raw) -match 'DOMAIN=langflow\.example\.com') {
    Invoke-EnvSetup -EnvFile $EnvFile
}

# If domain is still placeholder after prompting the user, abort.
if ((Get-Content $EnvFile -Raw) -match 'DOMAIN=langflow\.example\.com') {
    Write-Err "DOMAIN was not updated. Please enter a domain name or server IP address and re-run."
    exit 1
}

# Auto-generate any passwords left empty after prompting
$GeneratedPasswords = @()

$LangflowPass = Get-EnvValue -Key 'LANGFLOW_SUPERUSER_PASSWORD' -EnvFile $EnvFile
if ([string]::IsNullOrWhiteSpace($LangflowPass)) {
    $LangflowPass = New-RandomPassword
    Set-EnvValue -Key 'LANGFLOW_SUPERUSER_PASSWORD' -Value $LangflowPass -EnvFile $EnvFile
    $GeneratedPasswords += 'LANGFLOW_SUPERUSER_PASSWORD'
    Write-Info "Generated password for LANGFLOW_SUPERUSER_PASSWORD."
}

$PostgresPass = Get-EnvValue -Key 'POSTGRES_PASSWORD' -EnvFile $EnvFile
if ([string]::IsNullOrWhiteSpace($PostgresPass)) {
    $PostgresPass = New-RandomPassword
    Set-EnvValue -Key 'POSTGRES_PASSWORD' -Value $PostgresPass -EnvFile $EnvFile
    $GeneratedPasswords += 'POSTGRES_PASSWORD'
    Write-Info "Generated password for POSTGRES_PASSWORD."
}

if ($GeneratedPasswords.Count -gt 0) {
    Write-Warn "Auto-generated passwords have been saved to .env -- keep that file safe."
}

Write-Info ".env is configured."

# Convert bare IP to sslip.io domain for automatic HTTPS.
$CurrentDomain = Get-EnvValue -Key 'DOMAIN' -EnvFile $EnvFile
if ($CurrentDomain -match '^\d+\.\d+\.\d+\.\d+$') {
    $IpFromDomain = $CurrentDomain
    $SslipDomain  = ($CurrentDomain -replace '\.', '-') + '.sslip.io'
    Set-EnvValue -Key 'DOMAIN' -Value $SslipDomain -EnvFile $EnvFile
    Write-Info "Using sslip.io domain for HTTPS: $SslipDomain"
} elseif ($CurrentDomain -match '^(\d+)-(\d+)-(\d+)-(\d+)\.sslip\.io$') {
    # Already converted on a previous run — extract the IP for the Droplet default.
    $IpFromDomain = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
} else {
    $IpFromDomain = ''
}

# ---------------------------------------------------------------------------
# Prompt for Droplet connection details
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Enter your Droplet connection details." -ForegroundColor Cyan
Write-Host "(Press Enter to accept defaults shown in brackets.)" -ForegroundColor Cyan
Write-Host ""

if ($IpFromDomain) {
    $DropletIp = Read-Host "Droplet IP address [$IpFromDomain]"
    if ([string]::IsNullOrWhiteSpace($DropletIp)) { $DropletIp = $IpFromDomain }
} else {
    $DropletIp = Read-Host "Droplet IP address"
}

$SshUser = Read-Host "SSH user [root]"
if ([string]::IsNullOrWhiteSpace($SshUser)) { $SshUser = "root" }

$DefaultKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
Write-Host "  SSH private key path. Use the full Windows path, e.g. C:\Users\you\.ssh\id_ed25519" -ForegroundColor DarkGray
$SshKeyPath = Read-Host "Path to SSH private key [$DefaultKeyPath]"
if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
    $SshKeyPath = $DefaultKeyPath
}
# Expand %USERPROFILE% etc. but not ~; full paths are expected.
$SshKeyPath = [System.Environment]::ExpandEnvironmentVariables($SshKeyPath)

if (-not (Test-Path $SshKeyPath)) {
    Write-Err "SSH key not found at: $SshKeyPath"
    Write-Err "Use the full path, e.g. C:\Users\$env:USERNAME\.ssh\id_ed25519"
    Write-Err "To generate a new key run: ssh-keygen -t ed25519"
    exit 1
}

$RemoteDir = Read-Host "Remote directory to deploy into [/opt/langflow-digitalocean]"
if ([string]::IsNullOrWhiteSpace($RemoteDir)) { $RemoteDir = "/opt/langflow-digitalocean" }

# ---------------------------------------------------------------------------
# Common SSH options
# ---------------------------------------------------------------------------
$SshOpts = @(
    "-i", $SshKeyPath,
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "PasswordAuthentication=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "ConnectTimeout=30",
    "-o", "ServerAliveInterval=60",
    "-o", "ServerAliveCountMax=3"
)

# ---------------------------------------------------------------------------
# Test connectivity
# ---------------------------------------------------------------------------
Write-Info "Testing SSH connection to ${SshUser}@${DropletIp}..."
$testResult = & ssh @SshOpts "${SshUser}@${DropletIp}" "echo ok" 2>&1
if ($LASTEXITCODE -ne 0 -or $testResult -notmatch 'ok') {
    Write-Err "Could not connect to ${SshUser}@${DropletIp}."
    Write-Err "Check the IP address, SSH key, and that port 22 is reachable."
    Write-Err "SSH output: $testResult"
    exit 1
}
Write-Info "Connection successful."

# ---------------------------------------------------------------------------
# Create remote directory and copy files
# ---------------------------------------------------------------------------
Write-Info "Creating remote directory $RemoteDir..."
& ssh @SshOpts "${SshUser}@${DropletIp}" "mkdir -p '${RemoteDir}/docs'"
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to create remote directory. Check that the SSH user has write access."
    exit 1
}

Write-Info "Copying project files to Droplet..."
$FilesToCopy = @(
    ".env",
    ".env.example",
    "docker-compose.yml",
    "Caddyfile",
    "setup.sh"
)

foreach ($File in $FilesToCopy) {
    $LocalPath = Join-Path $ScriptDir $File
    if (Test-Path $LocalPath) {
        Write-Host "  -> $File" -ForegroundColor DarkGray
        & scp @SshOpts "$LocalPath" "${SshUser}@${DropletIp}:${RemoteDir}/$File"
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to copy $File to Droplet."
            exit 1
        }
    } else {
        Write-Warn "$File not found locally -- skipping."
    }
}

$DocsDir = Join-Path $ScriptDir "docs"
if (Test-Path $DocsDir) {
    Write-Host "  -> docs/" -ForegroundColor DarkGray
    & scp @SshOpts -r "$DocsDir" "${SshUser}@${DropletIp}:${RemoteDir}/"
}

Write-Info "Files copied successfully."

# Strip Windows CRLF line endings from all copied text files.
# BOM removal is handled separately by setup.sh using Python (sed hex escapes are
# locale-dependent and can overmatch in a UTF-8 locale).
Write-Info "Normalising line endings on Droplet..."
& ssh @SshOpts "${SshUser}@${DropletIp}" "find '${RemoteDir}' -maxdepth 2 -type f | xargs sed -i 's/\r//g'"

# ---------------------------------------------------------------------------
# Make setup.sh executable and run it
# ---------------------------------------------------------------------------
Write-Info "Running setup.sh on the Droplet..."
Write-Warn "This will take 5-10 minutes while Docker and the Langflow image are downloaded."
Write-Host ""

# .env is already fully configured locally, so setup.sh on the Droplet will
# skip its interactive prompts and proceed straight to the deployment.
# -tt forces TTY allocation so setup.sh output streams back in real time.
& ssh @SshOpts -tt "${SshUser}@${DropletIp}" "chmod +x '${RemoteDir}/setup.sh' && cd '${RemoteDir}' && sudo bash setup.sh"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Err "setup.sh exited with an error. Check the output above."
    Write-Err "You can SSH in and investigate: ssh -i $SshKeyPath ${SshUser}@${DropletIp}"
    exit 1
}

Write-Host ""
Write-Info "Deployment complete. See the summary above for your Langflow URL."

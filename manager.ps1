# --- CONFIGURATION ---
$ScriptPath = $MyInvocation.MyCommand.Path
$ConfigUrl = "https://raw.githubusercontent.com/ke9/adolock/main/config.json"
$ScriptUrl = "https://raw.githubusercontent.com/ke9/adolock/main/Manager.ps1"
$LocalConfig = "C:\Scripts\config.json"

# --- 1. SELF-UPDATE LOGIC ---
try {
    $RemoteScript = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing
    $CurrentScriptContent = Get-Content $ScriptPath -Raw
    
    if ($RemoteScript.Content -ne $CurrentScriptContent) {
        $RemoteScript.Content | Set-Content $ScriptPath
        Write-Host "Script updated. Restarting on next run."
        exit
    }
} catch { Write-Warning "Could not check for script updates." }

# --- 2. FETCH & PARSE CONFIG ---
try {
    Invoke-WebRequest -Uri $ConfigUrl -OutFile $LocalConfig -UseBasicParsing
    $Config = Get-Content $LocalConfig | ConvertFrom-Json
} catch {
    Write-Error "Failed to download config. Exiting to be safe."
    exit
}

if (-not $Config.Enabled) { exit }

# --- 3. SCHEDULE CHECK ---
$Now = Get-Date
$CurrentDay = $Now.DayOfWeek.ToString()
$CurrentHour = $Now.Hour

$IsBlackout = $Config.BlackoutPeriods | Where-Object {
    $_.Day -eq $CurrentDay -and $CurrentHour -ge $_.StartHour -and $CurrentHour -lt $_.EndHour
}

# --- 4. THE EVICTION ---
if ($IsBlackout) {
    # Get all sessions
    $Sessions = quser | Select-String -Pattern "Active|Disc"
    
    foreach ($Session in $Sessions) {
        $Line = $Session.ToString().Trim()
        $Data = $Line -split "\s+"
        
        $UserName = $Data[0].Replace(">", "")
        $SessionId = if ($Data[1] -match "^\d+$") { $Data[1] } else { $Data[2] }

        # Check if user is an Admin
        $IsAdmin = (New-Object Security.Principal.WindowsPrincipal(
            [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        
        # We check local group membership for the specific user
        $UserGroups = net user $UserName
        if ($UserGroups -notmatch "Administrators") {
            Write-Host "Logging off non-admin user: $UserName"
            logoff $SessionId
        }
    }
}
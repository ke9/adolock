# --- CONFIGURATION ---
$ScriptPath = $MyInvocation.MyCommand.Path
$LogFile = "C:\adolock\activity.log"
$ConfigUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/config.json"
$ScriptUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/manager.ps1"
$LocalConfig = "C:\adolock\config.json"

# --- HELPER: LOGGING FUNCTION ---
function Write-Log {
    param([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] $Message"
    Add-Content -Path $LogFile -Value $LogEntry
    Write-Host $LogEntry
}

Write-Log "--- Run Started ---"
Write-Log "Script path: $ScriptPath"

# --- 1. SELF-UPDATE LOGIC ---
try {
    $RemoteScript = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 10
    $CurrentScriptContent = Get-Content $ScriptPath -Raw
    
    if ($RemoteScript.Content -ne $CurrentScriptContent) {
        Write-Log "New script version detected. Updating and restarting..."
        $RemoteScript.Content | Set-Content $ScriptPath
        exit
    }
} catch { 
    Write-Log "Update check failed: $($_.Exception.Message)" 
}

# --- 2. FETCH & PARSE CONFIG ---
try {
    Invoke-WebRequest -Uri $ConfigUrl -OutFile $LocalConfig -UseBasicParsing -TimeoutSec 10
    $Config = Get-Content $LocalConfig | ConvertFrom-Json
} catch {
    Write-Log "CRITICAL: Failed to download config. Aborting run to prevent errors."
    exit
}

if (-not $Config.Enabled) { 
    Write-Log "Script disabled via config flag. Exiting."
    exit 
}

# --- 3. SCHEDULE CHECK ---
$Now = Get-Date
$CurrentDay = $Now.DayOfWeek.ToString()
$CurrentHour = $Now.Hour

$IsBlackout = $Config.BlackoutPeriods | Where-Object {
    $_.Day -eq $CurrentDay -and $CurrentHour -ge $_.StartHour -and $CurrentHour -lt $_.EndHour
}

# --- 4. THE EVICTION ---
if ($IsBlackout) {
    Write-Log "Blackout period active ($CurrentDay at $CurrentHour:00). Checking for users..."
    
    # Get sessions (handling potential empty results)
    $Sessions = quser 2>$null | Select-String -Pattern "Active|Disc"
    
    foreach ($Session in $Sessions) {
        $Line = $Session.ToString().Trim()
        $Data = $Line -split "\s+"
        
        $UserName = $Data[0].Replace(">", "")
        # Session ID is usually the 2nd or 3rd column depending on session state
        $SessionId = if ($Data[1] -match "^\d+$") { $Data[1] } else { $Data[2] }

        # Check for Admin status
        $UserGroups = net user $UserName 2>$null
        if ($UserGroups -notmatch "Administrators") {
            Write-Log "ACTION: Logging off non-admin user: $UserName (Session: $SessionId)"
            logoff $SessionId
        } else {
            Write-Log "SKIP: User $UserName is an Administrator."
        }
    }
} else {
    Write-Log "System in 'Allowed' state. No users removed."
}

Write-Log "--- Run Finished ---"
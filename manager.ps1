



# --- CONFIGURATION ---
$ScriptPath = $MyInvocation.MyCommand.Path
$LogFile = "C:\adolock\activity.log"
$ConfigUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/config.json"
$ScriptUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/manager.ps1"
$LocalConfig = "C:\adolock\config.json"

# Clear any existing web sessions/proxies that might hang
[System.Net.ServicePointManager]::DefaultConnectionLimit = 1
[System.Net.ServicePointManager]::ReusePort = $false

# Suppress progress bars to prevent hanging in background tasks
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message)
    $LogDir = "C:\adolock"
    $Path = "$LogDir\activity.log"
    
    # Ensure directory exists
    if (!(Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force }

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] $Message"
    
    # Use -PassThru and Out-File with -Append for better file handle management
    $LogEntry | Out-File -FilePath $Path -Append -Encoding utf8 -ErrorAction SilentlyContinue
    Write-Host $LogEntry
}

Write-Log "--- Run Started ---"

# --- 1. SELF-UPDATE LOGIC (With Normalization) ---
try {
    $RemoteScript = (Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 10).Content
    $CurrentScriptContent = Get-Content $ScriptPath -Raw
    
    # Normalize line endings to compare text content only
    $NormalizedRemote = $RemoteScript -replace "`r`n", "`n" -replace "`r", "`n"
    $NormalizedLocal = $CurrentScriptContent -replace "`r`n", "`n" -replace "`r", "`n"

    if ($NormalizedRemote.Trim() -ne $NormalizedLocal.Trim()) {
        Write-Log "New script version detected. Updating..."
        # Force UTF8 without BOM to keep things consistent
        [System.IO.File]::WriteAllText($ScriptPath, $RemoteScript)
        Write-Log "Update complete. Exiting current process."
        [Environment]::Exit(0)
    }
} catch { 
    Write-Log "Update check failed: $($_.Exception.Message)" 
}

# --- 2. FETCH & PARSE CONFIG ---
try {
    Invoke-WebRequest -Uri $ConfigUrl -OutFile $LocalConfig -UseBasicParsing -TimeoutSec 10
    $Config = Get-Content $LocalConfig | ConvertFrom-Json
} catch {
    Write-Log "CRITICAL: Failed to download config. Aborting."
    exit 1
}

if (-not $Config.Enabled) { 
    Write-Log "Script disabled via config. Exiting."
    exit 0
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
    Write-Log "Blackout period active. Checking sessions..."
    
    # quser throws an error if no one is logged in; we catch that silently
    $UserList = quser 2>$null
    if ($null -eq $UserList) {
        Write-Log "No active sessions found."
    } else {
        $Sessions = $UserList | Select-String -Pattern "Active|Disc"
        foreach ($Session in $Sessions) {
            $Line = $Session.ToString().Trim()
            $Data = $Line -split "\s+"
            
            # Handling the > symbol for current user
            $UserName = $Data[0].Replace(">", "")
            $SessionId = if ($Data[1] -match "^\d+$") { $Data[1] } else { $Data[2] }

            $UserGroups = net user $UserName 2>$null
            if ($UserGroups -notmatch "Administrators") {
                Write-Log "ACTION: Logging off user: $UserName (ID: $SessionId)"
                logoff $SessionId
            }
        }
    }
}

Write-Log "--- Run Finished ---"
[System.FlushConsoleInputBuffer] # Optional: clear any pending input
[Environment]::Exit(0)

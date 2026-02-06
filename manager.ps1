



# --- CONFIGURATION ---
$ScriptPath = $MyInvocation.MyCommand.Path
$LogFile = "C:\adolock\activity.log"
$ConfigUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/config.json"
$ScriptUrl = "https://raw.githubusercontent.com/ke9/adolock/v1/manager.ps1"
$LocalConfig = "C:\adolock\config.json"
$SecretsFile = "C:\adolock\secrets.json"
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

function Send-LogoutEmail {
    param([string]$LoggedUser)
    
    if (-not (Test-Path $SecretsFile)) {
        Write-Log "ERROR: Secrets file missing. Cannot send email."
        return
    }

    $Secrets = Get-Content $SecretsFile | ConvertFrom-Json
    $Subject = "User Evicted: $LoggedUser"
    $Body = "The user '$LoggedUser' was logged off at $(Get-Date)."
    
    try {
        $SecurePass = ConvertTo-SecureString $Secrets.SmtpPass -AsPlainText -Force
        $Creds = New-Object System.Management.Automation.PSCredential($Secrets.SmtpUser, $SecurePass)
        
        Send-MailMessage -From $Secrets.EmailFrom -To $Secrets.EmailTo -Subject $Subject -Body $Body `
            -SmtpServer $Secrets.SmtpServer -Port $Secrets.SmtpPort -UseSsl -Credential $Creds
        Write-Log "Email sent for: $LoggedUser"
    } catch {
        Write-Log "Mail Error: $($_.Exception.Message)"
    }
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
}
catch { 
    Write-Log "Update check failed: $($_.Exception.Message)" 
}

# --- 2. FETCH & PARSE CONFIG ---
Write-Log "Fetching config file"
try {
    Invoke-WebRequest -Uri $ConfigUrl -OutFile $LocalConfig -UseBasicParsing -TimeoutSec 10
    Write-Log "Config file downloaded."
    $Config = Get-Content $LocalConfig | ConvertFrom-Json
    Write-Log "Config file $LocalConfig loaded."
    Write-Log "Config : $Config"

}
catch {
    Write-Log "CRITICAL: Failed to download config. Aborting."
    [Environment]::Exit(0)
}

if (-not $Config.Enabled) { 
    Write-Log "Script disabled via config. Exiting."
    [Environment]::Exit(0)
}

Write-Log "Config file schedule enabled."


# --- 3. SCHEDULE CHECK ---
$CurrentTime = (Get-Date).TimeOfDay
$CurrentDay = (Get-Date).DayOfWeek.ToString()

# 2. Check against the new JSON structure
$IsBlackout = $Config.BlackoutPeriods | Where-Object {
    $_.DayOfWeek -eq $CurrentDay -and 
    $CurrentTime -ge [TimeSpan]$_.StartTime -and 
    $CurrentTime -lt [TimeSpan]$_.EndTime
}

Write-Log "Now $Now, day: $CurrentDay, hour: $CurrentHour" 

if ($IsBlackout) {


    # --- 4. THE EVICTION ---
    Write-Log "Blackout period active. Checking sessions..."
    
    # quser throws an error if no one is logged in; we catch that silently
    $UserList = quser 2>$null
    if ($null -eq $UserList) {
        Write-Log "No active sessions found."
    }
    else {
        $Sessions = $UserList | Select-String -Pattern "Active|Disc"
        foreach ($Session in $Sessions) {
            $Line = $Session.ToString().Trim()
            $Data = $Line -split "\s+"
    
            $UserName = $Data[0].Replace(">", "")
            $SessionId = if ($Data[1] -match "^\d+$") { $Data[1] } else { $Data[2] }

            Write-Log "Processing user $UserName"

            # ROBUST CHECK: Check if the user is a member of the local Administrators group by SID
            # This works regardless of system language (S-1-5-32-544 is always the Admin group)
            $IsAdmin = $false
            try {
                $GroupSid = "S-1-5-32-544" # Well-known SID for Built-in Administrators
                $User = New-Object System.Security.Principal.NTAccount($UserName)
                $Sid = $User.Translate([System.Security.Principal.SecurityIdentifier])
        
                # Get local group members
                $AdminMembers = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue
                if ($AdminMembers.SID -contains $Sid) {
                    $IsAdmin = $true
                }
            }
            catch {
                Write-Log "Error checking permissions for ${UserName}: $($_.Exception.Message)"
            }

            if (-not $IsAdmin) {
                Write-Log "ACTION: Logging off user: $UserName (ID: $SessionId)"
                Send-LogoutEmail -LoggedUser $UserName
                logoff $SessionId
            }
            else {
                Write-Log "SKIP: User $UserName is an Administrator."
            }
        }
    }
}
else {
    Write-Log "No blackout period active. Exiting."
}

Write-Log "--- Run Finished ---"
[System.FlushConsoleInputBuffer] # Optional: clear any pending input
[Environment]::Exit(0)





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
    
    $MachineName = $env:COMPUTERNAME

    if (-not (Test-Path $SecretsFile)) {
        Write-Log "ERROR: Secrets file missing. Cannot send email."
        return
    }

    $Secrets = Get-Content $SecretsFile | ConvertFrom-Json
    $Subject = "User Evicted: $LoggedUser"
   # $Body = "The user '$LoggedUser' was logged off at $(Get-Date)."
    $Body = "The user '$LoggedUser' was logged off from machine '$MachineName' at $(Get-Date)."
    
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

    # --- 4. THE EVICTION (ADAPTED FOR WINDOWS 11 HOME) ---
    Write-Log "Blackout period active. Checking sessions..."
    
    # Get interactive logon sessions (LogonType 2 = Interactive, 10 = Remote)
    # This works on Home/Family editions where quser is missing.
    $LogonSessions = Get-CimInstance -ClassName Win32_LogonSession | Where-Object { $_.LogonType -in @(2, 10) }

    if ($null -eq $LogonSessions) {
        Write-Log "No active interactive sessions found."
    }
    else {
        foreach ($Session in $LogonSessions) {
            # Get the actual Account object associated with this session
            $UserInfo = Get-CimAssociatedInstance -InputObject $Session -ResultClassName Win32_Account -ErrorAction SilentlyContinue
            
            if ($null -eq $UserInfo) { continue }

            $UserName = $UserInfo.Name
            $SessionId = $Session.LogonId # This is the unique ID for logoff
            
            Write-Log "Processing user $UserName"

            # --- ROBUST ADMIN CHECK ---
            $IsAdmin = $false
            try {
                $GroupSid = "S-1-5-32-544" 
                $Sid = $UserInfo.SID # CIM already gives us the SID, no need to translate!
        
                $AdminMembers = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue
                if ($AdminMembers.SID -contains $Sid) {
                    $IsAdmin = $true
                }
            }
            catch {
                Write-Log "Error checking permissions for ${UserName}: $($_.Exception.Message)"
            }

            if (-not $IsAdmin) {
                Write-Log "ACTION: Logging off user: $UserName"
                Send-LogoutEmail -LoggedUser $UserName
    
                # Forced Logoff using CIM
                # Flag 0 = Logoff, Flag 4 = Forced Logoff
                try {
                    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
                    Invoke-CimMethod -InputObject $OS -MethodName "Win32Shutdown" -Arguments @{ Flags = 4 }
                    Write-Log "Logoff command sent successfully."
                } catch {
                    Write-Log "Logoff FAILED: $($_.Exception.Message)"
                }
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
[Environment]::Exit(0)

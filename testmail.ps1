
$SecretsFile = "secrets.json"

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

Send-LogoutEmail -LoggedUser "coco"

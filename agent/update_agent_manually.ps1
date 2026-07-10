# Run this script in an Elevated (Administrator) PowerShell terminal to update the agent.

$serviceName = "tcp-tunnel-agent"
$sourceExe = "agent.exe"
$targetDir = "C:\tcp_tunnel_agent"
$targetExe = "$targetDir\agent.exe"
$settingsFile = "$targetDir\agent_settings.json"
$xmlFile = "$targetDir\tcp_tunnel_agent_service.xml"

# 1. Stop the running service
Write-Host "[*] Stopping $serviceName service..."
Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Force kill any remaining agent processes just in case
$proc = Get-Process -Name "agent" -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "[*] Killing remaining agent processes..."
    Stop-Process -Name "agent" -Force -ErrorAction SilentlyContinue
}

# 2. Copy the newly compiled binary
if (Test-Path $sourceExe) {
    Write-Host "[*] Copying new agent.exe binary to $targetDir..."
    Copy-Item -Path $sourceExe -Destination $targetExe -Force
} else {
    Write-Warning "[-] Compiled agent binary not found at $sourceExe"
}

# 3. Optional: Align connection token
# Enter the token from your Flutter app here if you want to sync it:
$appToken = "ab582572-acac-467a-b21f-712cf0c49b20"

if ($appToken -and $appToken -ne "changeme") {
    Write-Host "[*] Updating agent token to match Flutter app ($appToken)..."
    
    # Update agent_settings.json
    $jsonObj = @{ token = $appToken }
    $jsonObj | ConvertTo-Json -Compress | Out-File -FilePath $settingsFile -Encoding utf8 -Force
    
    # Update tcp_tunnel_agent_service.xml
    if (Test-Path $xmlFile) {
        $xmlContent = Get-Content -Path $xmlFile
        # Replace the token parameter inside <arguments>
        $xmlContent = $xmlContent -replace '--token [a-f0-9\-]+', "--token $appToken"
        $xmlContent | Out-File -FilePath $xmlFile -Encoding utf8 -Force
    }
}

# 4. Start the service
Write-Host "[*] Starting $serviceName service..."
Start-Service -Name $serviceName

Write-Host "[+] Done! The agent has been updated and restarted successfully." -ForegroundColor Green

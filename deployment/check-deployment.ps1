
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

$MutexName = "Local\MedicalBillingDeployment"
$ManifestUrl = "https://raw.githubusercontent.com/omarpeguero/medical-billing-data-platform/main/deployment/approved-version.json"
$ImagePattern = '^ghcr\.io/omarpeguero/medical-billing-dbt:sha-[a-fA-F0-9]{40}$'

$StateDir = Join-Path $PSScriptRoot ".state"
$FailedImagePath = Join-Path $StateDir "failed-image.json"
$DeployScript = Join-Path $PSScriptRoot "deploy.ps1"

# ---------------------------------------------------------
# Step 1: Acquire deployment lock
# ---------------------------------------------------------

$DeploymentMutex = [System.Threading.Mutex]::new($false, $MutexName)
$LockAcquired = $false

try {
    try {
        $LockAcquired = $DeploymentMutex.WaitOne(0)

        if (-not $LockAcquired) {
            Write-Host "Another deployment check is running. Skipping."
            return
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # The previous process terminated without releasing the lock.
        # Windows transfers mutex ownership to this process.
        $LockAcquired = $true
        Write-Warning "Previous deployment process terminated unexpectedly."
    }

    Write-Host "Deployment lock acquired." -ForegroundColor Green

    # -----------------------------------------------------
    # Step 2: Retrieve approved version from GitHub
    # -----------------------------------------------------

    Write-Host "Checking GitHub for approved deployment version..."

    try {
        $Manifest = Invoke-RestMethod `
            -Uri $ManifestUrl `
            -Method Get `
            -TimeoutSec 20
    }
    catch {
        throw "Unable to retrieve deployment manifest from GitHub: $($_.Exception.Message)"
    }

    # -----------------------------------------------------
    # Step 3: Validate manifest
    # -----------------------------------------------------

    if ($Manifest.environment -ne "local") {
        throw "Unexpected deployment environment."
    }

    $ApprovedImage = $Manifest.image

    if (-not ($ApprovedImage -is [string]) -or
        $ApprovedImage -cnotmatch $ImagePattern) {
        throw "Invalid approved image in GitHub manifest."
    }

    Write-Host "Approved image: $ApprovedImage" -ForegroundColor Green

    # -----------------------------------------------------
    # Step 4: Check previous deployment failures
    # -----------------------------------------------------

    if (Test-Path $FailedImagePath) {
        $FailedDeployment = Get-Content $FailedImagePath -Raw |
            ConvertFrom-Json

        if ($FailedDeployment.image -eq $ApprovedImage) {
            Write-Warning "This image previously failed deployment."
            Write-Warning "Automatic retry is blocked until a different image is approved or the failure marker is cleared."
            return
        }
    }

    # -----------------------------------------------------
    # Step 5: Dry-run mode
    # -----------------------------------------------------

    if ($DryRun) {
        Write-Host "Dry run complete. No deployment attempted."
        return
    }

    # -----------------------------------------------------
    # Step 6: Execute deployment
    # -----------------------------------------------------

    Write-Host "Executing deployment engine..."

    try {
        & $DeployScript -Image $ApprovedImage

        # A successful deployment clears any previous failure marker.
        if (Test-Path $FailedImagePath) {
            Remove-Item $FailedImagePath -Force
        }

        Write-Host "Automatic deployment check completed successfully." -ForegroundColor Green
    }
    catch {
        # -------------------------------------------------
        # Step 7: Record failed deployment attempt
        # -------------------------------------------------

        New-Item -ItemType Directory -Path $StateDir -Force |
            Out-Null

        $FailureRecord = [ordered]@{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            image     = $ApprovedImage
            error     = $_.Exception.Message
        }

        $FailureRecord |
            ConvertTo-Json |
            Set-Content $FailedImagePath -Encoding UTF8

        throw "Automatic deployment failed. This image is now blocked from automatic retry. $($_.Exception.Message)"
    }
}
finally {
    # -----------------------------------------------------
    # Step 8: Release deployment lock
    # -----------------------------------------------------

    if ($LockAcquired) {
        $DeploymentMutex.ReleaseMutex()
        Write-Host "Deployment lock released."
    }

    $DeploymentMutex.Dispose()
}

param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ManifestUrl = "https://raw.githubusercontent.com/omarpeguero/medical-billing-data-platform/main/deployment/approved-version.json"

$ImagePattern = '^ghcr\.io/omarpeguero/medical-billing-dbt:sha-[a-fA-F0-9]{40}$'

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

if ($Manifest.environment -ne "local") {
    throw "Unexpected deployment environment."
}

$ApprovedImage = $Manifest.image

if (-not ($ApprovedImage -is [string]) -or
    $ApprovedImage -cnotmatch $ImagePattern) {
    throw "Invalid approved image in GitHub manifest."
}

Write-Host "Approved image: $ApprovedImage" -ForegroundColor Green


# Check whether this image previously failed deployment.
$StateDir = Join-Path $PSScriptRoot ".state"
$FailedImagePath = Join-Path $StateDir "failed-image.json"

if (Test-Path $FailedImagePath) {
    $FailedDeployment = Get-Content $FailedImagePath -Raw |
        ConvertFrom-Json

    if ($FailedDeployment.image -eq $ApprovedImage) {
        Write-Warning "This image previously failed deployment."
        Write-Warning "Automatic retry is blocked until a different image is approved or the failure marker is cleared."
        return
    }
}


if ($DryRun) {
    Write-Host "Dry run complete. No deployment attempted."
    return
}

$DeployScript = Join-Path $PSScriptRoot "deploy.ps1"

Write-Host "Executing deployment engine..."


try {
    & $DeployScript -Image $ApprovedImage

    # Remove an old failure marker after successful deployment.
    if (Test-Path $FailedImagePath) {
        Remove-Item $FailedImagePath -Force
    }
}
catch {
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

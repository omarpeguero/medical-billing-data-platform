param(
    [Parameter(Mandatory = $true)]
    [string]$Image,

    [switch]$SimulateFailure,

    [switch]$LockAlreadyHeld
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

$ImagePattern = '^ghcr\.io/omarpeguero/medical-billing-dbt:sha-[a-fA-F0-9]{40}$'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvPath = Join-Path $ProjectRoot "medical_billing_airflow/.env"
$ComposePath = Join-Path $ProjectRoot "medical_billing_airflow/docker-compose.yml"
$StateDir = Join-Path $PSScriptRoot ".state"
$BackupPath = Join-Path $StateDir "airflow.env.backup"

$ContainerName = "medical_billing_airflow"
$TimeoutSeconds = 120
$PollSeconds = 5

# ---------------------------------------------------------
# Helper functions
# ---------------------------------------------------------

function Write-DeploymentHistory {
    param(
        [string]$PreviousImage,
        [string]$RequestedImage,
        [string]$Status,
        [string]$Details = ""
    )

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    $HistoryPath = Join-Path $StateDir "deployment-history.jsonl"

    $Record = [ordered]@{
        timestamp       = (Get-Date).ToUniversalTime().ToString("o")
        previous_image  = $PreviousImage
        requested_image = $RequestedImage
        status          = $Status
        details         = $Details
    }

    $Json = $Record | ConvertTo-Json -Compress
    Add-Content -Path $HistoryPath -Value $Json -Encoding UTF8
}

function Get-AirflowImage {
    $ContainerImageLines = @(
        docker inspect $ContainerName `
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Cannot inspect Airflow container: $ContainerName"
    }

    $ImageLine = $ContainerImageLines |
        Where-Object { $_ -match '^DBT_IMAGE=' } |
        Select-Object -First 1

    if (-not $ImageLine) {
        throw "DBT_IMAGE is missing from the Airflow container."
    }

    return $ImageLine.Substring("DBT_IMAGE=".Length).Trim()
}

function Wait-AirflowHealthy {
    param(
        [int]$Timeout = 120,
        [int]$Interval = 5
    )

    $Deadline = (Get-Date).AddSeconds($Timeout)

    Write-Host "Waiting for Airflow health check..."

    while ((Get-Date) -lt $Deadline) {
        $HealthStatus = docker inspect $ContainerName `
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' 2>$null

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect Airflow health."
        }

        switch ($HealthStatus.Trim()) {
            "healthy" {
                Write-Host "Airflow health check passed." -ForegroundColor Green
                return
            }

            "unhealthy" {
                throw "Airflow reported an unhealthy status."
            }

            "no-healthcheck" {
                throw "Airflow container has no configured health check."
            }
        }

        Start-Sleep -Seconds $Interval
    }

    throw "Airflow did not become healthy within $Timeout seconds."
}

function Set-ConfiguredImage {
    param([string]$NewImage)

    $EnvLines = @(Get-Content $EnvPath)

    $UpdatedLines = @(
        foreach ($Line in $EnvLines) {
            if ($Line -match '^DBT_IMAGE=') {
                "DBT_IMAGE=$NewImage"
            }
            else {
                $Line
            }
        }
    )

    [System.IO.File]::WriteAllLines(
        $EnvPath,
        [string[]]$UpdatedLines,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Restart-Airflow {
    docker compose --env-file $EnvPath -f $ComposePath config --quiet

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose configuration validation failed."
    }

    docker compose --env-file $EnvPath -f $ComposePath up `
        -d --no-deps --force-recreate airflow

    if ($LASTEXITCODE -ne 0) {
        throw "Airflow container recreation failed."
    }
}

function Assert-AirflowImage {
    param([string]$ExpectedImage)

    $ContainerState = docker inspect $ContainerName `
        --format '{{.State.Running}}' 2>$null

    if ($LASTEXITCODE -ne 0 -or
        $ContainerState.Trim() -ne "true") {
        throw "Airflow container is not running."
    }

    $ActualImage = Get-AirflowImage

    if ($ActualImage -ne $ExpectedImage) {
        throw "Airflow image mismatch. Expected: $ExpectedImage. Actual: $ActualImage"
    }

    Write-Host "Airflow image configuration verified." -ForegroundColor Green
}

function Write-HistorySafely {
    param(
        [string]$PreviousImage,
        [string]$RequestedImage,
        [string]$Status,
        [string]$Details = ""
    )

    try {
        Write-DeploymentHistory `
            -PreviousImage $PreviousImage `
            -RequestedImage $RequestedImage `
            -Status $Status `
            -Details $Details

        Write-Host "Deployment history recorded: $Status" -ForegroundColor Green
    }
    catch {
        Write-Warning "Unable to write deployment history: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------
# Step 1: Validate requested image
# ---------------------------------------------------------

if ($Image -cnotmatch $ImagePattern) {
    throw "Invalid image reference. Expected ghcr.io/omarpeguero/medical-billing-dbt:sha-<40-character Git SHA>"
}

Write-Host "Image reference validated." -ForegroundColor Green

# ---------------------------------------------------------
# Step 2: Verify Docker availability
# ---------------------------------------------------------

docker info --format '{{.ServerVersion}}' | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Docker is not available. Start Docker Desktop and retry."
}

Write-Host "Docker daemon is available." -ForegroundColor Green

# ---------------------------------------------------------
# Step 3: Pull and verify Docker image
# ---------------------------------------------------------

Write-Host "Pulling image: $Image"

docker pull $Image

if ($LASTEXITCODE -ne 0) {
    throw "Docker image pull failed. Deployment aborted."
}

docker image inspect $Image --format '{{.Id}}' | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Image verification failed. Deployment aborted."
}

Write-Host "Preflight image checks passed." -ForegroundColor Green

# ---------------------------------------------------------
# Step 4: Read current deployment state
# ---------------------------------------------------------

if (-not (Test-Path $EnvPath)) {
    throw "Airflow deployment .env file was not found: $EnvPath"
}

$ImageLine = Get-Content $EnvPath |
    Where-Object { $_ -match '^DBT_IMAGE=' } |
    Select-Object -First 1

if (-not $ImageLine) {
    throw "DBT_IMAGE is missing from the Airflow .env file."
}

$CurrentImage = $ImageLine.Substring("DBT_IMAGE=".Length).Trim()
$RunningImage = Get-AirflowImage

Write-Host "Currently configured image: $CurrentImage"
Write-Host "Running Airflow image:       $RunningImage"
Write-Host "Requested image:             $Image"

# ---------------------------------------------------------
# Step 5: Idempotency and consistency checks
# ---------------------------------------------------------

if ($CurrentImage -ne $RunningImage) {
    throw "Deployment state mismatch: .env and Airflow container differ. Reconcile before deploying."
}

if ($CurrentImage -eq $Image) {
    Write-Host "No deployment required. Airflow is up to date." -ForegroundColor Green
    return
}

Write-Host "New image version detected. Deployment required." -ForegroundColor Yellow

# ---------------------------------------------------------
# Step 6: Back up current configuration
# ---------------------------------------------------------

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

Copy-Item -Path $EnvPath -Destination $BackupPath -Force

Write-Host "Previous configuration backed up to: $BackupPath" -ForegroundColor Green

# ---------------------------------------------------------
# Step 7: Deploy image
# ---------------------------------------------------------

$DeploymentStatus = $null
$DeploymentDetails = ""
$DeploymentError = $null

try {
    Write-Host "Deploying image: $Image" -ForegroundColor Cyan

    Set-ConfiguredImage -NewImage $Image

    Restart-Airflow

    Assert-AirflowImage -ExpectedImage $Image

    Wait-AirflowHealthy `
        -Timeout $TimeoutSeconds `
        -Interval $PollSeconds

    if ($SimulateFailure) {
        throw "SIMULATED FAILURE: Testing automatic rollback."
    }

    $DeploymentStatus = "success"
    $DeploymentDetails = "Airflow recreated, image verified, and health check passed."

    Write-Host "Deployment configuration applied successfully." -ForegroundColor Green
    Write-Host "Deployed image: $Image"
}
catch {
    $DeploymentError = $_.Exception.Message

    Write-Host "Deployment failed: $DeploymentError" -ForegroundColor Red
    Write-Host "Restoring previous configuration..." -ForegroundColor Yellow

    # -----------------------------------------------------
    # Step 8: Automatic rollback
    # -----------------------------------------------------

    try {
        Copy-Item -Path $BackupPath -Destination $EnvPath -Force

        Restart-Airflow

        Assert-AirflowImage -ExpectedImage $CurrentImage

        Wait-AirflowHealthy `
            -Timeout $TimeoutSeconds `
            -Interval $PollSeconds

        $DeploymentStatus = "rolled_back"
        $DeploymentDetails = $DeploymentError

        Write-Host "Rollback verified. Previous version restored and Airflow is healthy." -ForegroundColor Green
    }
    catch {
        $RollbackError = $_.Exception.Message

        $DeploymentStatus = "rollback_failed"
        $DeploymentDetails = "Deployment error: $DeploymentError | Rollback error: $RollbackError"

        Write-Host "Automatic rollback failed: $RollbackError" -ForegroundColor Red
    }
}

# ---------------------------------------------------------
# Step 9: Record deployment outcome
# ---------------------------------------------------------

if ($DeploymentStatus) {
    Write-HistorySafely `
        -PreviousImage $CurrentImage `
        -RequestedImage $Image `
        -Status $DeploymentStatus `
        -Details $DeploymentDetails
}

# ---------------------------------------------------------
# Step 10: Report result
# ---------------------------------------------------------

switch ($DeploymentStatus) {
    "success" {
        Write-Host "Deployment completed successfully." -ForegroundColor Green
    }

    "rolled_back" {
        throw "Deployment failed, but automatic rollback succeeded. Original error: $DeploymentError"
    }

    "rollback_failed" {
        throw "Deployment and automatic rollback failed. Manual recovery required. $DeploymentDetails"
    }

    default {
        throw "Deployment ended in an unknown state."
    }
}

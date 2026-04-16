Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EnvMap {
    param([string]$Path)

    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        $parts = $trimmed -split "=", 2
        if ($parts.Length -eq 2) {
            $map[$parts[0]] = $parts[1]
        }
    }
    return $map
}

function Wait-HttpReady {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    }

    throw "Timed out waiting for service: $Url"
}

function Invoke-WeKnoraJson {
    param(
        [string]$Method,
        [string]$Url,
        [object]$Body,
        [hashtable]$Headers
    )

    $params = @{
        Method      = $Method
        Uri         = $Url
        TimeoutSec  = 60
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    if ($Headers) {
        $params["Headers"] = $Headers
    }

    return Invoke-RestMethod @params
}

function Ensure-Model {
    param(
        [string]$BaseApi,
        [string]$Token,
        [string]$Name,
        [string]$Type,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Provider,
        [int]$Dimension = 0
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $models = Invoke-WeKnoraJson -Method Get -Url "$BaseApi/models" -Body $null -Headers $headers
    $existing = $models.data | Where-Object { $_.name -eq $Name -and $_.type -eq $Type } | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    $payload = @{
        name        = $Name
        type        = $Type
        source      = "remote"
        description = "Provisioned by local bootstrap script"
        parameters  = @{
            base_url = $BaseUrl
            api_key  = $ApiKey
            provider = $Provider
        }
    }

    if ($Type -eq "Embedding") {
        $payload.parameters.embedding_parameters = @{
            dimension = $Dimension
        }
    }

    $created = Invoke-WeKnoraJson -Method Post -Url "$BaseApi/models" -Body $payload -Headers $headers
    return $created.data
}

function Ensure-KnowledgeBase {
    param(
        [string]$BaseApi,
        [string]$Token,
        [string]$Name,
        [string]$LLMModelID,
        [string]$EmbeddingModelID
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $list = Invoke-WeKnoraJson -Method Get -Url "$BaseApi/knowledge-bases" -Body $null -Headers $headers
    $kb = $list.data | Where-Object { $_.name -eq $Name } | Select-Object -First 1

    if (-not $kb) {
        $created = Invoke-WeKnoraJson -Method Post -Url "$BaseApi/knowledge-bases" -Headers $headers -Body @{
            name        = $Name
            type        = "document"
            description = "Local bootstrap knowledge base"
        }
        $kb = $created.data
    }

    Invoke-WeKnoraJson -Method Put -Url "$BaseApi/initialization/config/$($kb.id)" -Headers $headers -Body @{
        llmModelId       = $LLMModelID
        embeddingModelId = $EmbeddingModelID
        documentSplitting = @{
            chunkSize         = 512
            chunkOverlap      = 50
            separators        = @("`n`n", "`n", "。")
            parserEngineRules = @()
            enableParentChild = $false
        }
        multimodal = @{
            enabled = $false
        }
        storageProvider = "local"
        nodeExtract = @{
            enabled   = $false
            text      = ""
            tags      = @()
            nodes     = @()
            relations = @()
        }
        questionGeneration = @{
            enabled       = $false
            questionCount = 3
        }
    } | Out-Null

    return $kb
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
$envFile = Join-Path $repoRoot ".env.dashscope.local"
$localStateDir = Join-Path $repoRoot ".local"
$localStateFile = Join-Path $localStateDir "bootstrap.json"
$kbModuleRoot = Join-Path (Split-Path -Parent $repoRoot) "WeKnora-Knowledge-Service"
$kbModuleEnvFile = Join-Path $kbModuleRoot ".env.local"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Missing env file: $envFile"
}

$envMap = Get-EnvMap -Path $envFile
$frontendPort = $envMap["FRONTEND_PORT"]
$appPort = $envMap["APP_PORT"]
$baseApi = "http://127.0.0.1:$appPort/api/v1"

Write-Host "Starting WeKnora docker stack..."
docker compose --env-file $envFile up -d
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start WeKnora docker stack"
}

Write-Host "Waiting for WeKnora API on http://127.0.0.1:$appPort/health ..."
Wait-HttpReady -Url "http://127.0.0.1:$appPort/health"

$registerBody = @{
    username = $envMap["ADMIN_USERNAME"]
    email    = $envMap["ADMIN_EMAIL"]
    password = $envMap["ADMIN_PASSWORD"]
}

$authResponse = $null
try {
    $register = Invoke-WeKnoraJson -Method Post -Url "$baseApi/auth/register" -Body $registerBody -Headers $null
    $authResponse = Invoke-WeKnoraJson -Method Post -Url "$baseApi/auth/login" -Body @{
        email    = $envMap["ADMIN_EMAIL"]
        password = $envMap["ADMIN_PASSWORD"]
    } -Headers $null
} catch {
    $authResponse = Invoke-WeKnoraJson -Method Post -Url "$baseApi/auth/login" -Body @{
        email    = $envMap["ADMIN_EMAIL"]
        password = $envMap["ADMIN_PASSWORD"]
    } -Headers $null
}

$token = $authResponse.token
if (-not $token) {
    throw "Failed to obtain login token from WeKnora"
}

$tenantApiKey = $authResponse.tenant.api_key
if (-not $tenantApiKey) {
    throw "Failed to obtain tenant API key from WeKnora login response"
}

$chatModel = Ensure-Model `
    -BaseApi $baseApi `
    -Token $token `
    -Name $envMap["DASHSCOPE_CHAT_MODEL"] `
    -Type "KnowledgeQA" `
    -BaseUrl $envMap["DASHSCOPE_BASE_URL"] `
    -ApiKey $envMap["DASHSCOPE_API_KEY"] `
    -Provider "aliyun"

$embeddingModel = Ensure-Model `
    -BaseApi $baseApi `
    -Token $token `
    -Name $envMap["DASHSCOPE_EMBEDDING_MODEL"] `
    -Type "Embedding" `
    -BaseUrl $envMap["DASHSCOPE_BASE_URL"] `
    -ApiKey $envMap["DASHSCOPE_API_KEY"] `
    -Provider "aliyun" `
    -Dimension ([int]$envMap["DASHSCOPE_EMBEDDING_DIMENSION"])

$kb = Ensure-KnowledgeBase `
    -BaseApi $baseApi `
    -Token $token `
    -Name $envMap["SAMPLE_KB_NAME"] `
    -LLMModelID $chatModel.id `
    -EmbeddingModelID $embeddingModel.id

if (-not (Test-Path -LiteralPath $localStateDir)) {
    New-Item -ItemType Directory -Path $localStateDir | Out-Null
}

@{
    base_api           = $baseApi
    frontend_url       = "http://127.0.0.1:$frontendPort"
    admin_email        = $envMap["ADMIN_EMAIL"]
    tenant_api_key     = $tenantApiKey
    chat_model_id      = $chatModel.id
    embedding_model_id = $embeddingModel.id
    knowledge_base_id  = $kb.id
    knowledge_base_name = $kb.name
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localStateFile -Encoding UTF8

if (-not (Test-Path -LiteralPath $kbModuleRoot)) {
    throw "Missing sibling knowledge service directory: $kbModuleRoot"
}

@"
PORT=$($envMap["KB_MODULE_PORT"])
AUTH_MODE=dev
DEV_BEARER_TOKEN=$($envMap["KB_MODULE_DEV_TOKEN"])
WEKNORA_BASE_URL=http://host.docker.internal:$appPort/api/v1
WEKNORA_API_KEY=$tenantApiKey
REQUEST_TIMEOUT_SECONDS=60
JWT_SUBJECT_CLAIM=sub
JWT_USERNAME_CLAIM=preferred_username
JWT_EMAIL_CLAIM=email
"@ | Set-Content -LiteralPath $kbModuleEnvFile -Encoding UTF8

Write-Host "Starting standalone knowledge service..."
Push-Location $kbModuleRoot
try {
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start standalone knowledge service"
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "WeKnora UI: http://127.0.0.1:$frontendPort"
Write-Host "WeKnora API: $baseApi"
Write-Host "Standalone KB API: http://127.0.0.1:$($envMap["KB_MODULE_PORT"])/health"
Write-Host "Standalone KB dev token: $($envMap["KB_MODULE_DEV_TOKEN"])"

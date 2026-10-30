$ErrorActionPreference = "Stop"

$accountId = "286823679176"
$region = "us-east-1"
$bucketName = "my-image-storage-bucket-$accountId"
$tableName = "ImageMetadata"
$labRoleArn = "arn:aws:iam::$accountId`:role/LabRole"

# Las credenciales de AWS deben estar configuradas en el entorno (aws configure o AWS Academy CLI)
if (-not $env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION = $region }

Write-Host "=== 1. Creando Bucket S3: $bucketName ==="
try {
    aws s3api head-bucket --bucket $bucketName 2>$null
    Write-Host "Bucket ya existe."
} catch {
    aws s3api create-bucket --bucket $bucketName --region $region
    Write-Host "Bucket creado exitosamente."
}

Write-Host "=== 2. Creando Tabla DynamoDB: $tableName ==="
try {
    aws dynamodb describe-table --table-name $tableName --region $region 2>$null
    Write-Host "Tabla ya existe."
} catch {
    aws dynamodb create-table `
        --table-name $tableName `
        --attribute-definitions AttributeName=image_id,AttributeType=S `
        --key-schema AttributeName=image_id,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $region
    Write-Host "Tabla DynamoDB creada. Esperando estado ACTIVE..."
    aws dynamodb wait table-exists --table-name $tableName --region $region
}

Write-Host "=== 3. Empaquetando Funciones Lambda ==="
$workspace = "c:\Users\Bodega\Documents\estudio"
Set-Location $workspace
if (Test-Path "$workspace\upload_image.zip") { Remove-Item "$workspace\upload_image.zip" -Force }
if (Test-Path "$workspace\get_image_metadata.zip") { Remove-Item "$workspace\get_image_metadata.zip" -Force }

Compress-Archive -Path "$workspace\src\upload_image.py" -DestinationPath "$workspace\upload_image.zip"
Compress-Archive -Path "$workspace\src\get_image_metadata.py" -DestinationPath "$workspace\get_image_metadata.zip"

Write-Host "=== 4. Desplegando Lambda upload_image ==="
$envUpload = "Variables={BUCKET_NAME=$bucketName,TABLE_NAME=$tableName}"
try {
    aws lambda get-function --function-name upload_image --region $region 2>$null
    Write-Host "Actualizando codigo de upload_image..."
    aws lambda update-function-code --function-name upload_image --zip-file fileb://$workspace\upload_image.zip --region $region
    aws lambda update-function-configuration --function-name upload_image --environment $envUpload --timeout 30 --region $region
} catch {
    aws lambda create-function `
        --function-name upload_image `
        --runtime python3.12 `
        --role $labRoleArn `
        --handler upload_image.upload_image `
        --zip-file fileb://$workspace\upload_image.zip `
        --timeout 30 `
        --environment $envUpload `
        --region $region
    Write-Host "upload_image creada."
}

Write-Host "=== 5. Desplegando Lambda get_image_metadata ==="
$envGet = "Variables={TABLE_NAME=$tableName}"
try {
    aws lambda get-function --function-name get_image_metadata --region $region 2>$null
    Write-Host "Actualizando codigo de get_image_metadata..."
    aws lambda update-function-code --function-name get_image_metadata --zip-file fileb://$workspace\get_image_metadata.zip --region $region
    aws lambda update-function-configuration --function-name get_image_metadata --environment $envGet --timeout 30 --region $region
} catch {
    aws lambda create-function `
        --function-name get_image_metadata `
        --runtime python3.12 `
        --role $labRoleArn `
        --handler get_image_metadata.get_image_metadata `
        --zip-file fileb://$workspace\get_image_metadata.zip `
        --timeout 30 `
        --environment $envGet `
        --region $region
    Write-Host "get_image_metadata creada."
}

Write-Host "=== 6. Configurando API Gateway ImageMetadataAPI ==="
$apiName = "ImageMetadataAPI"
$apisJson = aws apigateway get-rest-apis --region $region | ConvertFrom-Json
$existingApi = $apisJson.items | Where-Object { $_.name -eq $apiName }

if ($existingApi) {
    $apiId = $existingApi.id
    Write-Host "API Gateway ya existe con ID: $apiId"
} else {
    $newApi = aws apigateway create-rest-api --name $apiName --description "API para subir y consultar metadatos de imagenes" --region $region | ConvertFrom-Json
    $apiId = $newApi.id
    Write-Host "API Gateway creado con ID: $apiId"
}

$resourcesJson = aws apigateway get-resources --rest-api-id $apiId --region $region | ConvertFrom-Json
$rootId = ($resourcesJson.items | Where-Object { $_.path -eq "/" }).id

# 6.1 Recurso /upload
$uploadResource = $resourcesJson.items | Where-Object { $_.path -eq "/upload" }
if (-not $uploadResource) {
    $uploadResource = aws apigateway create-resource --rest-api-id $apiId --parent-id $rootId --path-part "upload" --region $region | ConvertFrom-Json
}
$uploadResourceId = $uploadResource.id

# POST /upload -> upload_image
$uploadUri = "arn:aws:apigateway:$region`:lambda:path/2015-03-31/functions/arn:aws:lambda:$region`:$accountId`:function:upload_image/invocations"
try {
    aws apigateway put-method --rest-api-id $apiId --resource-id $uploadResourceId --http-method POST --authorization-type "NONE" --region $region 2>$null
} catch {}
aws apigateway put-integration --rest-api-id $apiId --resource-id $uploadResourceId --http-method POST --type AWS_PROXY --integration-http-method POST --uri $uploadUri --region $region

# Permiso Lambda upload_image
try {
    aws lambda add-permission --function-name upload_image --statement-id apigateway-upload-post --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$region`:$accountId`:$apiId/*/POST/upload" --region $region 2>$null
} catch {}

# 6.2 Recurso /metadata
$metadataResource = $resourcesJson.items | Where-Object { $_.path -eq "/metadata" }
if (-not $metadataResource) {
    $metadataResource = aws apigateway create-resource --rest-api-id $apiId --parent-id $rootId --path-part "metadata" --region $region | ConvertFrom-Json
}
$metadataResourceId = $metadataResource.id

# 6.3 Recurso /metadata/{image_id}
$resourcesJson = aws apigateway get-resources --rest-api-id $apiId --region $region | ConvertFrom-Json
$imageIdResource = $resourcesJson.items | Where-Object { $_.path -eq "/metadata/{image_id}" }
if (-not $imageIdResource) {
    $imageIdResource = aws apigateway create-resource --rest-api-id $apiId --parent-id $metadataResourceId --path-part "{image_id}" --region $region | ConvertFrom-Json
}
$imageIdResourceId = $imageIdResource.id

# GET /metadata/{image_id} -> get_image_metadata
$metadataUri = "arn:aws:apigateway:$region`:lambda:path/2015-03-31/functions/arn:aws:lambda:$region`:$accountId`:function:get_image_metadata/invocations"
try {
    aws apigateway put-method --rest-api-id $apiId --resource-id $imageIdResourceId --http-method GET --authorization-type "NONE" --request-parameters "method.request.path.image_id=true" --region $region 2>$null
} catch {}
aws apigateway put-integration --rest-api-id $apiId --resource-id $imageIdResourceId --http-method GET --type AWS_PROXY --integration-http-method POST --uri $metadataUri --region $region

# Permiso Lambda get_image_metadata
try {
    aws lambda add-permission --function-name get_image_metadata --statement-id apigateway-metadata-get --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$region`:$accountId`:$apiId/*/GET/metadata/*" --region $region 2>$null
} catch {}

# Desplegar API en Stage prod
Write-Host "=== 7. Desplegando API Gateway a Stage 'prod' ==="
$deployment = aws apigateway create-deployment --rest-api-id $apiId --stage-name prod --region $region | ConvertFrom-Json

$invokeUrl = "https://$apiId.execute-api.$region.amazonaws.com/prod"
Write-Host "============================================="
Write-Host "INFRAESTRUCTURA DESPLEGADA EXITOSAMENTE:"
Write-Host "Bucket S3: $bucketName"
Write-Host "DynamoDB: $tableName"
Write-Host "Lambda 1: upload_image"
Write-Host "Lambda 2: get_image_metadata"
Write-Host "API Gateway URL: $invokeUrl"
Write-Host "Endpoint Upload: $invokeUrl/upload"
Write-Host "Endpoint Metadata: $invokeUrl/metadata/{image_id}"
Write-Host "============================================="

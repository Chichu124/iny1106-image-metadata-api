$ErrorActionPreference = "Stop"

# Generar una imagen JPG de prueba con System.Drawing
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 100, 100
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.Clear([System.Drawing.Color]::Blue)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$font = New-Object System.Drawing.Font("Arial", 10)
$graphics.DrawString("AWS Test", $font, $brush, 10, 40)
$graphics.Dispose()
$testImagePath = "c:\Users\Bodega\Documents\estudio\test_image.jpg"
$bmp.Save($testImagePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
$bmp.Dispose()

Write-Host "Imagen de prueba creada en: $testImagePath"

# 1. Enviar solicitud POST /upload
$uploadUrl = "https://er6bwcycph.execute-api.us-east-1.amazonaws.com/prod/upload"
Write-Host "Enviando POST a $uploadUrl..."

$imageBytes = [System.IO.File]::ReadAllBytes($testImagePath)
$imageText = [System.Convert]::ToBase64String($imageBytes)

# Probar envio directo de la imagen
$response = Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $imageText -ContentType "application/octet-stream"
Write-Host "Respuesta de Upload:"
$response | ConvertTo-Json

# Extraer el image_id de la URL retornada
# Ejemplo url: https://my-image-storage-bucket-286823679176.s3.amazonaws.com/abcd1234.jpg
$imageUrl = $response.url
$fileName = $imageUrl.Substring($imageUrl.LastIndexOf('/') + 1)
$imageId = $fileName.Replace(".jpg", "")

Write-Host "`n>>> Image ID obtenido: $imageId"

# 2. Enviar solicitud GET /metadata/{image_id}
$metadataUrl = "https://er6bwcycph.execute-api.us-east-1.amazonaws.com/prod/metadata/$imageId"
Write-Host "Enviando GET a $metadataUrl..."

$metadataResponse = Invoke-RestMethod -Uri $metadataUrl -Method Get
Write-Host "Respuesta de Metadata:"
$metadataResponse | ConvertTo-Json

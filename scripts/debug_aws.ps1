# scripts/debug_aws.ps1

Write-Host "🔍 DIAGNÓSTICO DE CONECTIVIDAD AWS" -ForegroundColor Cyan

# 1. CARGA EXPLÍCITA
Import-Module AWS.Tools.Common
Import-Module AWS.Tools.RDS

# 2. AUTENTICACIÓN HARDCODEADA (Para aislar el problema)
# Usamos us-east-1 porque es donde Terraform dijo que estaban tus cosas
$Region = "us-east-1" 
Write-Host "   Configurando región: $Region" -ForegroundColor Gray

try {
    Initialize-AWSDefaultConfiguration -ProfileName "default" -Region $Region -ErrorAction Stop
    Write-Host "   ✅ Configuración inicializada." -ForegroundColor Green
} catch {
    Write-Host "   ❌ FALLO DE AUTENTICACIÓN: $_" -ForegroundColor Red
    exit
}

# 3. PRUEBA DE IDENTIDAD
Write-Host "`n🧪 PRUEBA 1: ¿Quién soy?" -ForegroundColor Yellow
try {
    $Identity = Get-STSCallerIdentity
    Write-Host "   Conectado como: $($Identity.Arn)" -ForegroundColor Green
} catch {
    Write-Host "   ❌ No tienes salida a internet o credenciales válidas." -ForegroundColor Red
    Write-Host "   Detalle: $($_.Exception.Message)" -ForegroundColor Gray
    exit
}

# 4. PRUEBA DE FALLO CONTROLADO (El Bug del "Not Found")
Write-Host "`n🧪 PRUEBA 2: Buscar algo que no existe (Simulando el error)" -ForegroundColor Yellow
$GhostDB = "lab-db-recovered"

Write-Host "   Intentando hacer Get-RDSDBInstance de '$GhostDB'..."
try {
    # Esta es la línea que rompe tu orquestador
    $null = Get-RDSDBInstance -DBInstanceIdentifier $GhostDB -ErrorAction Stop
    Write-Host "   ⚠️ ¡Sorpresa! La instancia existe." -ForegroundColor Magenta
} catch {
    # Vamos a ver qué tipo de error es
    $ErrorMsg = $_.Exception.Message
    if ($ErrorMsg -match "not found") {
        Write-Host "   ✅ COMPORTAMIENTO ESPERADO: AWS devolvió 'Not Found'." -ForegroundColor Green
        Write-Host "      El script debería capturar esto y seguir, no fallar." -ForegroundColor Gray
    } else {
        Write-Host "   ❌ ERROR INESPERADO: $ErrorMsg" -ForegroundColor Red
    }
}

# scripts/debug_restore.ps1

# 1. Cargar Módulos
Import-Module AWS.Tools.Common
Import-Module AWS.Tools.RDS

# 2. Configurar Entorno (Simulamos lo que hace el orquestador)
$TerraformDir = "../terraform"
$TFOutput = terraform -chdir=$TerraformDir output -json | ConvertFrom-Json
$RDS_ID = $TFOutput.rds_identifier.value
$Region = $TFOutput.region.value

# Autenticación
Initialize-AWSDefaultConfiguration -ProfileName "default" -Region $Region

# 3. Obtener Datos de la DB Original
Write-Host "--- DIAGNÓSTICO DE VARIABLES ---" -ForegroundColor Cyan
Write-Host "ID Original: $RDS_ID"

$OriginalDb = Get-RDSDBInstance -DBInstanceIdentifier $RDS_ID
if (-not $OriginalDb) { Write-Error "No encuentro la DB original"; exit }

# EXTRACCIÓN DE DATOS CRÍTICOS
$VpcSgIds = $OriginalDb.VpcSecurityGroups.VpcSecurityGroupId
$SubnetGroup = $OriginalDb.DBSubnetGroup.DBSubnetGroupName

Write-Host "Security Group ID: '$VpcSgIds'" -ForegroundColor Yellow
Write-Host "Subnet Group Name: '$SubnetGroup'" -ForegroundColor Yellow

# 4. Buscar el último Snapshot
$Snap = Get-RDSDBSnapshot -DBInstanceIdentifier $RDS_ID | Sort-Object SnapshotCreateTime -Descending | Select-Object -First 1
if (-not $Snap) { Write-Error "No encuentro Snapshots"; exit }

Write-Host "Usando Snapshot: $($Snap.DBSnapshotIdentifier) (Status: $($Snap.Status))" -ForegroundColor Green

# 5. INTENTO DE RESTAURACIÓN (Simulación)
$NewDbId = "lab-db-recovered"

# Verificar si ya existe (fantasma)
if (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId -ErrorAction SilentlyContinue) {
    Write-Warning "¡OJO! La instancia $NewDbId YA EXISTE (Estado: $((Get-RDSDBInstance -DBInstanceIdentifier $NewDbId).DBInstanceStatus))"
    Write-Warning "Esto impide crear una nueva. Debes borrarla manualmente o esperar a que termine de borrarse."
    exit
}

Write-Host "Lanzando restauración..." -ForegroundColor Cyan
try {
    Restore-RDSDBInstanceFromDBSnapshot `
        -DBSnapshotIdentifier $Snap.DBSnapshotIdentifier `
        -DBInstanceIdentifier $NewDbId `
        -VpcSecurityGroupId $VpcSgIds `
        -DBSubnetGroupName $SubnetGroup `
        -PubliclyAccessible $false `
        -ErrorAction Stop
    
    Write-Host "✅ ¡ÉXITO! Comando aceptado por AWS." -ForegroundColor Green
} catch {
    Write-Host "❌ ERROR FATAL DE AWS:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
}

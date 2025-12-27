# ==============================================================================
#  ORQUESTADOR MAESTRO v4.0 (Modular & Configurable)
# ==============================================================================
$ErrorActionPreference = "Stop"

# 1. CARGA DE CONFIGURACIÓN Y MÓDULOS
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Config = Get-Content (Join-Path $PSScriptRoot "config/settings.json") | ConvertFrom-Json
Import-Module (Join-Path $PSScriptRoot "modules/DrUtils") -Force

# Rutas Absolutas (Calculadas desde config)
$TerraformDir = Join-Path $ProjectRoot $Config.paths.terraform
$Inventory    = Join-Path $ProjectRoot $Config.paths.ansible_inventory
$FailPlaybook = Join-Path $ProjectRoot $Config.paths.ansible_playbooks $Config.playbooks.deploy_fail
$RepairPlaybook = Join-Path $ProjectRoot $Config.paths.ansible_playbooks $Config.playbooks.repair

# Validaciones Básicas
if (-not (Test-Path $Inventory)) { throw "Inventario no encontrado: $Inventory" }

# Cargar AWS Tools
Write-Host "🔌 Cargando AWS..." -ForegroundColor Gray
Import-Module AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.RDS
Initialize-AWSDefaultConfiguration -ProfileName $Config.aws.profile -Region $Config.aws.region_fallback

# ==============================================================================
# FASE 1: OBTENER ESTADO Y HACER BACKUP
# ==============================================================================
Write-Host "📸 FASE 1: Preparación..." -ForegroundColor Cyan

Push-Location $TerraformDir; try { $TFJson = terraform output -json } finally { Pop-Location }
$TFOutput = $TFJson | ConvertFrom-Json

$BackupTag = "$($Config.aws.backup_tag_prefix)$(Get-Date -Format 'yyyyMMdd-HHmm')"

# Llamada al Módulo (Función Limpia)
New-DrBackup -RdsId $TFOutput.rds_identifier.value `
             -DiskId $TFOutput.data_disk_id.value `
             -BackupTag $BackupTag `
             -TimeoutSeconds $Config.timeouts.backup_wait_seconds

# ==============================================================================
# FASE 2: EJECUCIÓN (INTENTO DE DESPLIEGUE)
# ==============================================================================
Write-Host "📦 FASE 2: Despliegue..." -ForegroundColor Cyan

$Result = Invoke-AnsibleRun -Inventory $Inventory -Playbook $FailPlaybook

if ($Result.ExitCode -eq 0) {
    Write-Host "✅ Éxito inesperado (¿El zip no era malicioso?)." -ForegroundColor Green
    exit 0
}

# ==============================================================================
# FASE 3: DETECCIÓN Y RECUPERACIÓN (AUTO-HEALING)
# ==============================================================================
Write-Host "❌ FALLO DETECTADO (Exit Code: $($Result.ExitCode))" -ForegroundColor Red
$LogPath = Join-Path $PSScriptRoot ($Config.project.logPrefix + ".txt")
$Result.Output | Out-File $LogPath

Write-Host "🚑 FASE 3: INICIANDO RECUPERACIÓN..." -ForegroundColor Magenta

try {
    # 1. Recuperación de Infraestructura (Llamada al Módulo)
    $NewDbHost = Restore-DrInfrastructure `
        -SnapshotTag $BackupTag `
        -OriginalDbId $TFOutput.rds_identifier.value `
        -OriginalVolId $TFOutput.data_disk_id.value `
        -Ec2Id $TFOutput.ec2_instance_id.value `
        -InventoryPath $Inventory

    # 2. Recuperación de Aplicación (Ansible)
    Write-Host "🛠️ Reconfigurando App con nueva BBDD..." -ForegroundColor Cyan
    $RepairResult = Invoke-AnsibleRun `
        -Inventory $Inventory `
        -Playbook $RepairPlaybook `
        -ExtraVars "new_db_host=$NewDbHost"

    if ($RepairResult.ExitCode -eq 0) {
        Write-Host "`n✅✅ SISTEMA RECUPERADO EXITOSAMENTE ✅✅" -ForegroundColor Green -BackgroundColor Black
    } else {
        Write-Host "❌ Falló la reparación de la App." -ForegroundColor Red
        Write-Host $RepairResult.Output -ForegroundColor Gray
    }

} catch {
    Write-Host "❌ CRITICAL: Falló el protocolo de recuperación. $_" -ForegroundColor Red
}

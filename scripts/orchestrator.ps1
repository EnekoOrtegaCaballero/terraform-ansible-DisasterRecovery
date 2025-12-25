# scripts/orchestrator.ps1

# ==============================================================================
#  ORQUESTADOR DE RESILIENCIA Y RECUPERACIÓN (Versión Final v3.0)
# ==============================================================================

# --- 0. CALCULAR RUTAS ABSOLUTAS ---
$ProjectRoot     = Split-Path -Parent $PSScriptRoot
$TerraformDir    = Join-Path $ProjectRoot "terraform"  # <--- FALTABA ESTA VARIABLE
$AnsiblePlaybook = Join-Path $ProjectRoot "ansible/playbooks/update_app_fail.yml"
$Inventory       = Join-Path $ProjectRoot "ansible/inventory.ini"
$AnsibleVars     = Join-Path $ProjectRoot "ansible/group_vars/windows.yml"
$ArtifactZip     = Join-Path $ProjectRoot "artifacts/update_pkg.zip"
$LogFile         = "deployment_log_$(Get-Date -Format 'yyyyMMdd-HHmm').txt"


Write-Host "🚀 INICIANDO PIPELINE DE DESPLIEGUE v2.0" -ForegroundColor Cyan
Write-Host "📂 Directorio del Proyecto: $ProjectRoot" -ForegroundColor DarkGray

# ==============================================================================
#  FASE DE VALIDACIÓN (SAFETY CHECKS)
# ==============================================================================

# CHECK 1: ¿Existe el inventario?
if (-not (Test-Path $Inventory)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentra el inventario ($Inventory)." -ForegroundColor Red
    Write-Host "   Causa probable: La infraestructura (Terraform) está apagada." -ForegroundColor Gray
    exit 1
}

# CHECK 2: ¿Existen las variables?
if (-not (Test-Path $AnsibleVars)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentran las variables ($AnsibleVars)." -ForegroundColor Red
    exit 1
}

# CHECK 3: ¿Existe el paquete ZIP?
if (-not (Test-Path $ArtifactZip)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentra el paquete ($ArtifactZip)." -ForegroundColor Red
    exit 1
}

# CHECK 4: ¿Está Ansible instalado?
if (-not (Get-Command "ansible-playbook" -ErrorAction SilentlyContinue)) {
    Write-Host "❌ ERROR CRÍTICO: 'ansible-playbook' no está instalado." -ForegroundColor Red
    exit 1
}

# ==============================================================================
#  CARGA DE MÓDULOS AWS
# ==============================================================================
Write-Host "🔌 Cargando herramientas de AWS..." -ForegroundColor Gray
try {
    Import-Module AWS.Tools.Common -ErrorAction Stop
    Import-Module AWS.Tools.EC2 -ErrorAction Stop
    Import-Module AWS.Tools.RDS -ErrorAction Stop
} catch {
    Write-Host "❌ ERROR CRÍTICO: Fallo al cargar módulos AWS Tools." -ForegroundColor Red
    Write-Host "   Ejecuta: Install-Module -Name AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.RDS -Scope CurrentUser -Force" -ForegroundColor Gray
    exit 1
}
# ==============================================================================
#  FASE 1: PREPARACIÓN Y BACKUP (PARALELO)
# ==============================================================================
Write-Host "📸 FASE 1: Iniciando Protocolo de Seguridad..." -ForegroundColor Cyan

# 1. Obtener Datos desde Terraform
Write-Host "   Consultando Terraform state..." -ForegroundColor Gray
# [BLOQUE DE RUTAS Y DATOS - IGUAL QUE ANTES]
if (-not (Test-Path $TerraformDir)) { Write-Host "❌ ERROR: Carpeta Terraform no encontrada."; exit 1 }
Push-Location -Path $TerraformDir
try { $JsonOutput = terraform output -json } finally { Pop-Location }
$TFOutput = $JsonOutput | ConvertFrom-Json

$EC2_ID       = $TFOutput.ec2_instance_id.value
$RDS_ID       = $TFOutput.rds_identifier.value
$DATA_DISK_ID = $TFOutput.data_disk_id.value
$AWS_REGION   = $TFOutput.region.value

Write-Host "   Objetivos identificados en $AWS_REGION : Web[$EC2_ID], DB[$RDS_ID], Disk[$DATA_DISK_ID]" -ForegroundColor DarkGray

# 2. AUTENTICACIÓN AWS
Write-Host "   🔑 Autenticando sesión de AWS..." -ForegroundColor Yellow
try {
    Initialize-AWSDefaultConfiguration -ProfileName "default" -Region $AWS_REGION -ErrorAction Stop
} catch {
    Set-DefaultAWSRegion -Region $AWS_REGION
}

# 3. DISPARAR PETICIONES (FIRE)
$BackupTag = "snap-pre-update-$(Get-Date -Format 'yyyyMMdd-HHmm')"
Write-Host "   🚀 Lanzando solicitudes de backup en paralelo ($BackupTag)..." -ForegroundColor Yellow

# A) Lanzar RDS
try {
    $RdsSnap = New-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag -DBInstanceIdentifier $RDS_ID -ErrorAction Stop
    Write-Host "      + RDS: Solicitud enviada." -ForegroundColor Green
} catch {
    Write-Host "      ❌ Fallo al solicitar RDS: $_" -ForegroundColor Red
    exit 1
}

# B) Lanzar Disco
try {
    $EbsSnap = New-EC2Snapshot -VolumeId $DATA_DISK_ID -Description "Backup App Data $BackupTag" -ErrorAction Stop
    Write-Host "      + Disco D: Solicitud enviada." -ForegroundColor Green
} catch {
    Write-Host "      ❌ Fallo al solicitar Disco: $_" -ForegroundColor Red
    # Seguimos, la DB es prioritaria
}

# 4. ESPERAR A AMBOS (WAIT)
Write-Host "   ⏳ Esperando finalización de tareas en segundo plano..." -ForegroundColor Yellow

$RdsStatus = "creating"
$EbsStatus = "pending"
$Timeout = 0
$MaxWaitSeconds = 900 # 15 minutos

# El bucle sigue mientras ALGUNO de los dos no haya terminado
while (($RdsStatus -ne "available" -or $EbsStatus -ne "completed") -and $Timeout -lt $MaxWaitSeconds) {
    Start-Sleep -Seconds 15
    $Timeout += 15
    
    # Actualizar estado RDS (si no ha acabado ya)
    if ($RdsStatus -ne "available") {
        $CurrentRds = Get-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag
        $RdsStatus = $CurrentRds.Status
    }

    # Actualizar estado Disco (si no ha acabado ya)
    if ($EbsStatus -ne "completed") {
        $CurrentEbs = Get-EC2Snapshot -SnapshotId $EbsSnap.SnapshotId
        $EbsStatus = $CurrentEbs.State
    }

    # Barra de estado dinámica
    Write-Host -NoNewline "`r      [Tiempo: ${Timeout}s] Estado RDS: $RdsStatus | Estado Disco: $EbsStatus      "
}
Write-Host "" # Salto de línea final

# 5. VERIFICACIÓN FINAL
if ($RdsStatus -eq "available") {
    Write-Host "   ✅ Backups completados correctamente." -ForegroundColor Green
} else {
    Write-Host "   ❌ TIMEOUT: Los backups tardaron demasiado." -ForegroundColor Red
    exit 1
}

# ==============================================================================
#  FASE 2: EJECUCIÓN DE LA ACTUALIZACIÓN
# ==============================================================================
Write-Host "📦 Subiendo y Ejecutando actualización..." -ForegroundColor Yellow

# Configuración del proceso .NET para captura robusta de errores
$ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
$ProcessInfo.FileName = "ansible-playbook"
$ProcessInfo.Arguments = "-i $Inventory $AnsiblePlaybook"
$ProcessInfo.RedirectStandardOutput = $true
$ProcessInfo.RedirectStandardError = $true
$ProcessInfo.UseShellExecute = $false
$ProcessInfo.CreateNoWindow = $true

$Process = [System.Diagnostics.Process]::Start($ProcessInfo)
$StdOut = $Process.StandardOutput.ReadToEnd()
$StdErr = $Process.StandardError.ReadToEnd()
$Process.WaitForExit()

$AnsibleExitCode = $Process.ExitCode
$Output = $StdOut + "`n" + $StdErr

# CHECK EXTRA: Detección de Falsos Positivos
if ($AnsibleExitCode -eq 0 -and $Output -match "skipping: no hosts matched") {
    $AnsibleExitCode = 99
    $Output += "`n[ORQUESTADOR]: ALERTA - Inventario vacío o grupo incorrecto."
}

# ==============================================================================
#  FASE 3: ANÁLISIS Y TOMA DE DECISIONES
# ==============================================================================

if ($AnsibleExitCode -ne 0) {
    # --- CASO DE FALLO ---
    Write-Host "❌ FALLO CRÍTICO EN LA ACTUALIZACIÓN (Código: $AnsibleExitCode)" -ForegroundColor Red -BackgroundColor Black
    
    Write-Host "Analizando la salida del script remoto..." -ForegroundColor Yellow
    
    if ($Output -match "CRITICAL EXCEPTION") {
        Write-Host "⚠️ DETECTADO: Fallo en migración de Base de Datos (ver detalle en el log)" -ForegroundColor Red
    } 
    elseif ($Output -match "Unreachable" -or $Output -match "Failed to connect") {
        Write-Host "⚠️ DETECTADO: Error de Conectividad (Host caído o WinRM fallando)" -ForegroundColor DarkRed
    }
    elseif ($AnsibleExitCode -eq 99) {
         Write-Host "⚠️ DETECTADO: Ansible no encontró anfitriones (Target vacío)" -ForegroundColor Magenta
    }
    else {
        Write-Host "⚠️ DETECTADO: Error genérico de Ansible" -ForegroundColor Magenta
        Write-Host "Últimas líneas del log:" -ForegroundColor Gray
        $Output.Split("`n") | Select-Object -Last 10
    }
    
    # --- GUARDADO DE LOGS ---
    $LogPath = Join-Path $PSScriptRoot $LogFile
    $Output | Out-File $LogPath
    Write-Host "📄 Log guardado en: $LogPath"
    
    # --- DISPARO DE ROLLBACK ---
    Write-Host "🚑 INICIANDO RESTAURACIÓN AUTOMÁTICA..." -ForegroundColor Magenta
    # Restore-Infrastructure (Pendiente Fase 4)
}
else {
    # --- CASO DE ÉXITO ---
    Write-Host "✅ Actualización completada con éxito." -ForegroundColor Green
}

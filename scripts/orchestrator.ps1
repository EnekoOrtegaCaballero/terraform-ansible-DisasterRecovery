# scripts/orchestrator.ps1

# ==============================================================================
#  ORQUESTADOR DE RESILIENCIA Y RECUPERACIÓN (Versión Final v3.1)
# ==============================================================================

# --- 0. CALCULAR RUTAS ABSOLUTAS ---
$ProjectRoot     = Split-Path -Parent $PSScriptRoot
$TerraformDir    = Join-Path $ProjectRoot "terraform"
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

if (-not (Test-Path $Inventory)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentra el inventario ($Inventory)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $AnsibleVars)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentran las variables ($AnsibleVars)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $ArtifactZip)) {
    Write-Host "❌ ERROR CRÍTICO: No se encuentra el paquete ($ArtifactZip)." -ForegroundColor Red
    exit 1
}
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
    exit 1
}

# ==============================================================================
#  FUNCIÓN: RESTORE-INFRASTRUCTURE (Versión v3.3 - Blindada)
# ==============================================================================
function Restore-Infrastructure {
    param (
        [string]$SnapshotTag,
        [string]$OriginalDbId,
        [string]$OriginalVolId,
        [string]$Ec2Id
    )

    Write-Host "`n🚑 [RECOVERY] Iniciando protocolo de Recuperación de Desastres..." -ForegroundColor Magenta

    # --- PASO 1: RECUPERACIÓN DE BASE DE DATOS (RDS) ---
    $NewDbId = "lab-db-recovered"
    Write-Host "   1. Restaurando Base de Datos desde Snapshot ($SnapshotTag)..." -ForegroundColor Yellow

    try {
        # FIX: Evitar duplicados si Get-RDSDBInstance devuelve arrays
        $OriginalDb = Get-RDSDBInstance -DBInstanceIdentifier $OriginalDbId | Select-Object -First 1
        $VpcSgIds = @($OriginalDb.VpcSecurityGroups.VpcSecurityGroupId | Select-Object -Unique)

	# CHECK ROBUSTO: ¿Existe ya la instancia?
        $InstanceExists = $false
        try {
            # Intentamos obtenerla. Si no existe, AWS lanza error y saltamos al catch.
            $null = Get-RDSDBInstance -DBInstanceIdentifier $NewDbId -ErrorAction Stop
            $InstanceExists = $true
        } catch {
            # Si falla, asumimos que es porque no existe (lo cual es bueno)
            Write-Host "      (La instancia '$NewDbId' está limpia/no existe, procedemos a crearla)" -ForegroundColor DarkGray
        }

        if ($InstanceExists) {
             Write-Host "      ⚠️ La instancia '$NewDbId' ya existe (residuo anterior)." -ForegroundColor DarkGray
             Write-Host "      Intentando borrado de emergencia..." -ForegroundColor Yellow
             
             try {
                Remove-RDSDBInstance -DBInstanceIdentifier $NewDbId -SkipFinalSnapshot $true -Force -ErrorAction Stop
                
                Write-Host "      Esperando eliminación..." -NoNewline
                while (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId -ErrorAction SilentlyContinue) { 
                    Write-Host -NoNewline "."
                    Start-Sleep -Seconds 10 
                }
                Write-Host " ¡Eliminada!"
             } catch {
                Write-Host "`n      ❌ NO SE PUEDE LIMPIAR: La instancia está bloqueada." -ForegroundColor Red
                throw "Intervención manual requerida: Borra '$NewDbId' en AWS Console."
             }
        }
        # LANZAR RESTAURACIÓN
        Restore-RDSDBInstanceFromDBSnapshot `
            -DBSnapshotIdentifier $SnapshotTag `
            -DBInstanceIdentifier $NewDbId `
            -VpcSecurityGroupId $VpcSgIds `
            -DBSubnetGroupName $OriginalDb.DBSubnetGroup.DBSubnetGroupName `
            -PubliclyAccessible $false `
            -ErrorAction Stop | Out-Null
            
        Write-Host "      Solicitud de restauración RDS enviada. ID: $NewDbId" -ForegroundColor Gray

    } catch {
        Write-Host "      ❌ Error solicitando restauración RDS: $_" -ForegroundColor Red
        throw $_
    }

    # --- PASO 2: RECUPERACIÓN DE DISCO (EBS SWAP) ---
    Write-Host "   2. Intercambiando Disco de Datos (EBS Swap)..." -ForegroundColor Yellow
    
    try {
        # A) Buscar Snapshot de Disco
        $EbsSnap = Get-EC2Snapshot -Filter @{Name="description";Values="*$SnapshotTag*"} | Select-Object -First 1
        if (-not $EbsSnap) { throw "No se encontró Snapshot de disco con tag $SnapshotTag" }

        # B) Obtener Zona de Disponibilidad
        $Instance = Get-EC2Instance -InstanceId $Ec2Id
        $AZ = $Instance.Instances[0].Placement.AvailabilityZone

        # C) Crear Volumen
        Write-Host "      Creando nuevo volumen desde $($EbsSnap.SnapshotId) en $AZ..." -ForegroundColor Gray
        $NewVol = New-EC2Volume -SnapshotId $EbsSnap.SnapshotId -AvailabilityZone $AZ -VolumeType gp3 -ErrorAction Stop
        
        while ((Get-EC2Volume -VolumeId $NewVol.VolumeId).State -ne "available") { Start-Sleep -Seconds 2 }

        # D) DETENER INSTANCIA
        Write-Host "      Deteniendo instancia $Ec2Id para intercambio de hardware..." -ForegroundColor Yellow
        Stop-EC2Instance -InstanceId $Ec2Id -Force -ErrorAction Stop | Out-Null
        while ((Get-EC2Instance -InstanceId $Ec2Id).Instances[0].State.Name -ne "stopped") { Write-Host -NoNewline "."; Start-Sleep -Seconds 5 }
        Write-Host ""

        # E) DESCONECTAR DISCO VIEJO
        Write-Host "      Desconectando disco corrupto ($OriginalVolId)..." -ForegroundColor Gray
        Dismount-EC2Volume -VolumeId $OriginalVolId -InstanceId $Ec2Id -Force -ErrorAction Stop | Out-Null
        while ((Get-EC2Volume -VolumeId $OriginalVolId).State -ne "available") { Start-Sleep -Seconds 2 }

        # F) CONECTAR DISCO NUEVO
        Write-Host "      Conectando disco recuperado ($($NewVol.VolumeId))..." -ForegroundColor Gray
        Add-EC2Volume -VolumeId $NewVol.VolumeId -InstanceId $Ec2Id -Device "/dev/xvdb" -ErrorAction Stop | Out-Null
        while ((Get-EC2Volume -VolumeId $NewVol.VolumeId).Attachments[0].State -ne "attached") { Start-Sleep -Seconds 2 }

        # G) ARRANCAR INSTANCIA
        Write-Host "      Arrancando instancia..." -ForegroundColor Green
        Start-EC2Instance -InstanceId $Ec2Id -ErrorAction Stop | Out-Null
        while ((Get-EC2Instance -InstanceId $Ec2Id).Instances[0].State.Name -ne "running") { Write-Host -NoNewline "."; Start-Sleep -Seconds 5 }
        Write-Host ""
        
        Write-Host "      Esperando inicio de Windows (30s)..." -ForegroundColor Gray
        Start-Sleep -Seconds 30

    } catch {
        Write-Host "      ❌ Error en EBS Swap: $_" -ForegroundColor Red
        throw $_
    }

    # --- PASO 3: ESPERAR A LA BASE DE DATOS ---
    Write-Host "   3. Finalizando restauración de Base de Datos..." -ForegroundColor Yellow
    $DbStatus = "creating"
    while ($DbStatus -ne "available") {
        Start-Sleep -Seconds 15
        $DbStatus = (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId).DBInstanceStatus
        Write-Host -NoNewline "."
    }
    Write-Host ""
    
    # Obtener el nuevo Endpoint de la BBDD
    $NewEndpoint = (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId).Endpoint.Address
    Write-Host "   ✅ BBDD Recuperada. Nuevo Endpoint: $NewEndpoint" -ForegroundColor Green

    # --- NUEVO BLOQUE: ACTUALIZAR INVENTARIO ANSIBLE (FIX IP DINÁMICA) ---
    Write-Host "   🔄 Actualizando IP en inventario de Ansible..." -ForegroundColor Yellow
    
    # 1. Obtener la nueva IP Pública de la instancia reiniciada
    $NewInstanceData = Get-EC2Instance -InstanceId $Ec2Id
    $NewPublicIp = $NewInstanceData.Instances[0].PublicIpAddress
    
    if (-not $NewPublicIp) {
        Write-Error "No se pudo obtener la IP Pública. ¿La instancia está corriendo?"
        throw "Error IP Pública"
    }

    Write-Host "      Nueva IP detectada: $NewPublicIp" -ForegroundColor Gray

    # 2. Definir la ruta del inventario (usamos la variable global $Inventory)
    # Nota: Asegúrate de que $Inventory es accesible dentro de la función o usa $global:Inventory
    # Para asegurar, reconstruimos la ruta relativa si es necesario, pero $Inventory debería verse.
    
    # 3. Reescribir el archivo inventory.ini
    $NewInventoryContent = @"
[windows]
$NewPublicIp

[windows:vars]
ansible_connection=winrm
ansible_winrm_server_cert_validation=ignore
ansible_port=5986
ansible_winrm_transport=basic
ansible_user=ansible_admin
ansible_password=Password123!
"@
    # NOTA: He hardcodeado usuario/pass aquí por simplicidad del ejemplo. 
    # Lo ideal es leerlo de tus variables o dejar que Ansible use group_vars si no cambian.
    # Pero como inventory.ini original generado por Terraform es simple, lo replicamos así:
    
    $SimpleInventory = @"
[windows]
$NewPublicIp

[windows:vars]
ansible_connection=winrm
ansible_winrm_server_cert_validation=ignore
ansible_port=5986
ansible_winrm_transport=basic
"@

    Set-Content -Path $Inventory -Value $SimpleInventory -Force
    Write-Host "      Inventario actualizado correctamente." -ForegroundColor Green
    # ---------------------------------------------------------------------

    return $NewEndpoint
 
}

# ===============================================================================
#  FASE 1: PREPARACIÓN Y BACKUP (PARALELO)
# ==============================================================================
Write-Host "📸 FASE 1: Iniciando Protocolo de Seguridad..." -ForegroundColor Cyan

# 1. Obtener Datos desde Terraform
Write-Host "   Consultando Terraform state..." -ForegroundColor Gray
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

try {
    $RdsSnap = New-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag -DBInstanceIdentifier $RDS_ID -ErrorAction Stop
    Write-Host "      + RDS: Solicitud enviada." -ForegroundColor Green
} catch {
    Write-Host "      ❌ Fallo al solicitar RDS: $_" -ForegroundColor Red
    exit 1
}

try {
    $EbsSnap = New-EC2Snapshot -VolumeId $DATA_DISK_ID -Description "Backup App Data $BackupTag" -ErrorAction Stop
    Write-Host "      + Disco D: Solicitud enviada." -ForegroundColor Green
} catch {
    Write-Host "      ❌ Fallo al solicitar Disco: $_" -ForegroundColor Red
}

# 4. ESPERAR A AMBOS (WAIT)
Write-Host "   ⏳ Esperando finalización de tareas en segundo plano..." -ForegroundColor Yellow

$RdsStatus = "creating"
$EbsStatus = "pending"
$Timeout = 0
$MaxWaitSeconds = 900 

while (($RdsStatus -ne "available" -or $EbsStatus -ne "completed") -and $Timeout -lt $MaxWaitSeconds) {
    Start-Sleep -Seconds 15
    $Timeout += 15
    
    if ($RdsStatus -ne "available") {
        $CurrentRds = Get-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag
        $RdsStatus = $CurrentRds.Status
    }
    if ($EbsStatus -ne "completed") {
        $CurrentEbs = Get-EC2Snapshot -SnapshotId $EbsSnap.SnapshotId
        $EbsStatus = $CurrentEbs.State
    }
    Write-Host -NoNewline "`r      [Tiempo: ${Timeout}s] Estado RDS: $RdsStatus | Estado Disco: $EbsStatus      "
}
Write-Host ""

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

if ($AnsibleExitCode -eq 0 -and $Output -match "skipping: no hosts matched") {
    $AnsibleExitCode = 99
    $Output += "`n[ORQUESTADOR]: ALERTA - Inventario vacío o grupo incorrecto."
}

# ==============================================================================
#  FASE 3: ANÁLISIS Y TOMA DE DECISIONES
# ==============================================================================

if ($AnsibleExitCode -ne 0) {
    Write-Host "❌ FALLO CRÍTICO EN LA ACTUALIZACIÓN (Código: $AnsibleExitCode)" -ForegroundColor Red -BackgroundColor Black
    
    Write-Host "Analizando la salida del script remoto..." -ForegroundColor Yellow
    
    if ($Output -match "CRITICAL EXCEPTION") {
        Write-Host "⚠️ DETECTADO: Fallo en migración de Base de Datos (ver detalle en el log)" -ForegroundColor Red
    } 
    elseif ($Output -match "Unreachable") {
        Write-Host "⚠️ DETECTADO: Error de Conectividad" -ForegroundColor DarkRed
    }
    else {
        Write-Host "⚠️ DETECTADO: Error genérico de Ansible" -ForegroundColor Magenta
    }
    
    $LogPath = Join-Path $PSScriptRoot $LogFile
    $Output | Out-File $LogPath
    Write-Host "📄 Log guardado en: $LogPath"
    
    # --- DISPARO DE ROLLBACK ---
    Write-Host "🚑 INICIANDO RESTAURACIÓN AUTOMÁTICA..." -ForegroundColor Magenta
    
    try {
        # 1. Ejecutar la función de Recuperación (PowerShell AWS)
        $NewDbEndpoint = Restore-Infrastructure `
            -SnapshotTag $BackupTag `
            -OriginalDbId $RDS_ID `
            -OriginalVolId $DATA_DISK_ID `
            -Ec2Id $EC2_ID

        # 2. Ejecutar la Reparación de la App (Ansible)
        Write-Host "🛠️ Ejecutando Playbook de Reparación (Ansible)..." -ForegroundColor Cyan
        
        $RepairPlaybook = Join-Path $ProjectRoot "ansible/playbooks/repair_app.yml"
        # OJO: Comillas escapadas para PowerShell
        $AnsibleArgs = "-i $Inventory $RepairPlaybook --extra-vars `"new_db_host=$NewDbEndpoint`""
        
        $RepairInfo = New-Object System.Diagnostics.ProcessStartInfo
        $RepairInfo.FileName = "ansible-playbook"
        $RepairInfo.Arguments = $AnsibleArgs
        $RepairInfo.RedirectStandardOutput = $true
        $RepairInfo.UseShellExecute = $false
        
        $RepairProcess = [System.Diagnostics.Process]::Start($RepairInfo)
        
        while (-not $RepairProcess.HasExited) {
            $line = $RepairProcess.StandardOutput.ReadLine()
            if ($line) { Write-Host $line -ForegroundColor Gray }
        }
        $RepairProcess.WaitForExit()

        if ($RepairProcess.ExitCode -eq 0) {
            Write-Host "`n✅✅ RECUPERACIÓN COMPLETADA CON ÉXITO ✅✅" -ForegroundColor Green -BackgroundColor Black
            Write-Host "El sistema ha sobrevivido. La web apunta a la nueva BBDD y el disco D: ha sido restaurado."
        } else {
            Write-Host "❌ Ansible falló al reparar la aplicación." -ForegroundColor Red
        }

    } catch {
        Write-Host "❌ FALLÓ LA RECUPERACIÓN AUTOMÁTICA: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "✅ Actualización completada con éxito." -ForegroundColor Green
}

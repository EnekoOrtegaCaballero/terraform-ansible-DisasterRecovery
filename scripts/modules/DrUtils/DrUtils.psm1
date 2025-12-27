# ==============================================================================
# MÓDULO: Disaster Recovery Utilities (DrUtils)
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCIÓN 1: BACKUPS PARALELOS
# ------------------------------------------------------------------------------
function New-DrBackup {
    param (
        [Parameter(Mandatory=$true)] [string]$RdsId,
        [Parameter(Mandatory=$true)] [string]$DiskId,
        [Parameter(Mandatory=$true)] [string]$BackupTag,
        [int]$TimeoutSeconds = 900
    )

    Write-Host "   🚀 Lanzando solicitudes de backup en paralelo ($BackupTag)..." -ForegroundColor Yellow

    # 1. Disparar (Fire)
    try {
        $RdsSnap = New-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag -DBInstanceIdentifier $RdsId -ErrorAction Stop
        Write-Host "      + RDS: Solicitud enviada." -ForegroundColor Green
    } catch { throw "Fallo al solicitar RDS Snapshot: $_" }

    try {
        $EbsSnap = New-EC2Snapshot -VolumeId $DiskId -Description "Backup App Data $BackupTag" -ErrorAction Stop
        Write-Host "      + Disco D: Solicitud enviada." -ForegroundColor Green
    } catch { Write-Warning "Fallo al solicitar Disco Snapshot: $_" }

    # 2. Esperar (Wait)
    Write-Host "   ⏳ Esperando finalización..." -ForegroundColor Yellow
    $RdsStatus = "creating"; $EbsStatus = "pending"; $Timer = 0

    while (($RdsStatus -ne "available" -or $EbsStatus -ne "completed") -and $Timer -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 15
        $Timer += 15
        
        if ($RdsStatus -ne "available") { $RdsStatus = (Get-RDSDBSnapshot -DBSnapshotIdentifier $BackupTag).Status }
        if ($EbsStatus -ne "completed") { $EbsStatus = (Get-EC2Snapshot -SnapshotId $EbsSnap.SnapshotId).State }
        
        Write-Host -NoNewline "`r      [${Timer}s] RDS: $RdsStatus | Disco: $EbsStatus      "
    }
    Write-Host ""

    if ($RdsStatus -eq "available") { Write-Host "   ✅ Backups completados." -ForegroundColor Green }
    else { throw "TIMEOUT esperando backups." }
}

# ------------------------------------------------------------------------------
# FUNCIÓN 2: EJECUTOR DE ANSIBLE (Wrapper .NET)
# ------------------------------------------------------------------------------
function Invoke-AnsibleRun {
    param (
        [string]$Inventory,
        [string]$Playbook,
        [string]$ExtraVars = $null
    )

    $ArgsList = "-i $Inventory $Playbook"
    if ($ExtraVars) { $ArgsList += " --extra-vars `"$ExtraVars`"" }

    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = "ansible-playbook"
    $ProcessInfo.Arguments = $ArgsList
    $ProcessInfo.RedirectStandardOutput = $true
    $ProcessInfo.RedirectStandardError = $true
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.CreateNoWindow = $true

    $Process = [System.Diagnostics.Process]::Start($ProcessInfo)
    
    # Lectura en tiempo real simplificada para logs
    $StdOut = $Process.StandardOutput.ReadToEnd()
    $StdErr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $Process.ExitCode
        Output   = $StdOut + "`n" + $StdErr
    }
}

# ------------------------------------------------------------------------------
# FUNCIÓN 3: RESTAURACIÓN DE INFRAESTRUCTURA (Tu función estrella)
# ------------------------------------------------------------------------------
function Restore-DrInfrastructure {
    param (
        [string]$SnapshotTag,
        [string]$OriginalDbId,
        [string]$OriginalVolId,
        [string]$Ec2Id,
        [string]$InventoryPath # Necesario para actualizar la IP
    )

    Write-Host "`n🚑 [RECOVERY] Iniciando protocolo de Recuperación..." -ForegroundColor Magenta
    $NewDbId = "lab-db-recovered"

    # A. RDS
    try {
        $OriginalDb = Get-RDSDBInstance -DBInstanceIdentifier $OriginalDbId | Select-Object -First 1
        $VpcSgIds = @($OriginalDb.VpcSecurityGroups.VpcSecurityGroupId | Select-Object -Unique)

        # Limpieza idempotente
        try { $null = Get-RDSDBInstance -DBInstanceIdentifier $NewDbId -ErrorAction Stop; $Exists=$true } catch { $Exists=$false }
        
        if ($Exists) {
            Write-Host "      ⚠️ Limpiando instancia anterior..." -ForegroundColor DarkGray
            Remove-RDSDBInstance -DBInstanceIdentifier $NewDbId -SkipFinalSnapshot $true -Force -ErrorAction Stop
            while (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId -ErrorAction SilentlyContinue) { Start-Sleep 10 }
        }

        Restore-RDSDBInstanceFromDBSnapshot -DBSnapshotIdentifier $SnapshotTag -DBInstanceIdentifier $NewDbId -VpcSecurityGroupId $VpcSgIds -DBSubnetGroupName $OriginalDb.DBSubnetGroup.DBSubnetGroupName -PubliclyAccessible $false -ErrorAction Stop | Out-Null
        Write-Host "      Solicitud RDS enviada." -ForegroundColor Gray
    } catch { throw "Error RDS Restore: $_" }

    # B. EBS SWAP
    try {
        $EbsSnap = Get-EC2Snapshot -Filter @{Name="description";Values="*$SnapshotTag*"} | Select-Object -First 1
        $AZ = (Get-EC2Instance -InstanceId $Ec2Id).Instances[0].Placement.AvailabilityZone

        Write-Host "      Intercambiando discos..." -ForegroundColor Yellow
        $NewVol = New-EC2Volume -SnapshotId $EbsSnap.SnapshotId -AvailabilityZone $AZ -VolumeType gp3 -ErrorAction Stop
        while ((Get-EC2Volume -VolumeId $NewVol.VolumeId).State -ne "available") { Start-Sleep 2 }

        Stop-EC2Instance -InstanceId $Ec2Id -Force -ErrorAction Stop | Out-Null
        while ((Get-EC2Instance -InstanceId $Ec2Id).Instances[0].State.Name -ne "stopped") { Start-Sleep 5 }

        Dismount-EC2Volume -VolumeId $OriginalVolId -InstanceId $Ec2Id -Force -ErrorAction Stop | Out-Null
        while ((Get-EC2Volume -VolumeId $OriginalVolId).State -ne "available") { Start-Sleep 2 }

        # USAMOS EL FIX CORRECTO: Add-EC2Volume
        Add-EC2Volume -VolumeId $NewVol.VolumeId -InstanceId $Ec2Id -Device "/dev/xvdb" -ErrorAction Stop | Out-Null
        while ((Get-EC2Volume -VolumeId $NewVol.VolumeId).Attachments[0].State -ne "attached") { Start-Sleep 2 }

        Start-EC2Instance -InstanceId $Ec2Id -ErrorAction Stop | Out-Null
        while ((Get-EC2Instance -InstanceId $Ec2Id).Instances[0].State.Name -ne "running") { Start-Sleep 5 }
        Write-Host "      Servidor reiniciado." -ForegroundColor Green
        Start-Sleep 30 # Espera WinRM
    } catch { throw "Error EBS Swap: $_" }

    # C. Esperar DB
    Write-Host "      Esperando disponibilidad de BBDD..." -ForegroundColor Yellow
    while ((Get-RDSDBInstance -DBInstanceIdentifier $NewDbId).DBInstanceStatus -ne "available") { Write-Host -NoNewline "."; Start-Sleep 15 }
    Write-Host ""
    $NewEndpoint = (Get-RDSDBInstance -DBInstanceIdentifier $NewDbId).Endpoint.Address

    # D. Actualizar IP Inventario
    $NewIp = (Get-EC2Instance -InstanceId $Ec2Id).Instances[0].PublicIpAddress
    if ($NewIp) {
        $InvContent = "[windows]`n$NewIp`n`n[windows:vars]`nansible_connection=winrm`nansible_winrm_server_cert_validation=ignore`nansible_port=5986`nansible_winrm_transport=basic"
        Set-Content -Path $InventoryPath -Value $InvContent -Force
        Write-Host "      Inventario actualizado ($NewIp)." -ForegroundColor Green
    }

    return $NewEndpoint
}

Export-ModuleMember -Function New-DrBackup, Invoke-AnsibleRun, Restore-DrInfrastructure

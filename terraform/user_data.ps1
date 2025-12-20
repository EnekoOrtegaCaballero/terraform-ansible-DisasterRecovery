<powershell>
# --- LOG DE DEPURACIÓN ---
Start-Transcript -Path "C:\Terraform-UserData-Log.txt" -Append

Write-Host "Iniciando configuración de WinRM con SSL..."

# 1. Configuración básica de Red y Ejecución
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force

# 2. Gestión de Usuarios (Inyección de Variable de Terraform)
# Terraform sustituirá ${admin_password} por el valor real antes de enviar el script
$user = "ansible_admin"
$password = ConvertTo-SecureString "${admin_password}" -AsPlainText -Force

# Crear usuario si no existe (Idempotencia básica)
$userExists = Get-LocalUser | Where-Object { $_.Name -eq $user }
if (-not $userExists) {
    New-LocalUser -Name $user -Password $password -Description "Automation Admin"
    Add-LocalGroupMember -Group "Administrators" -Member $user
    Write-Host "Usuario $user creado exitosamente."
}

# 3. Configuración del Registro para UAC (Token Filter)
# Permite que los administradores remotos tengan permisos completos
New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force

# 4. Generación de Certificado Autofirmado (Self-Signed)
# Creamos un certificado válido para el nombre de host actual
$Cert = New-SelfSignedCertificate -CertstoreLocation Cert:\LocalMachine\My -DnsName $env:COMPUTERNAME

# 5. Configurar WinRM para HTTPS
# Borramos listeners antiguos si existen para evitar conflictos
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains "Transport=HTTPS" } | Remove-Item -Recurse

# Creamos el nuevo Listener HTTPS usando el certificado generado
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $Cert.Thumbprint -Force

# 6. Configurar Firewall
# Abrimos el puerto 5986 (WinRM HTTPS)
# Nota: WinRM HTTP usa 5985 (Inseguro), HTTPS usa 5986 (Seguro)
New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow

# 7. Configuraciones extra de WinRM para Ansible
# Aumentar memoria y tiempos de espera para evitar fallos en despliegues grandes
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 1024
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true # Aún requerimos Basic Auth PERO va dentro del túnel HTTPS cifrado

Write-Host "Configuración WinRM HTTPS completada."
Stop-Transcript
</powershell>

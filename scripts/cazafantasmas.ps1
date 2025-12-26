# Copia y pega esto en tu terminal pwsh
$TargetName = "lab-db-recovered"
$Regions = @("us-east-1", "us-east-2", "eu-west-1", "eu-west-2", "eu-central-1", "sa-east-1")

Write-Host "🌍 Buscando '$TargetName' por el mundo..." -ForegroundColor Cyan

foreach ($Region in $Regions) {
    Write-Host "   🔎 Mirando en $Region..." -NoNewline
    try {
        $Instance = Get-RDSDBInstance -DBInstanceIdentifier $TargetName -Region $Region -ErrorAction SilentlyContinue
        if ($Instance) {
            Write-Host " ¡ENCONTRADA!" -ForegroundColor Red
            Write-Host "      Estado: $($Instance.DBInstanceStatus)" -ForegroundColor Yellow
            Write-Host "      Acción: Ve a la consola, cambia a la región $Region y bórrala." -ForegroundColor Gray
        } else {
            Write-Host " No está." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " Error de conexión (Saltando)." -ForegroundColor DarkGray
    }
}

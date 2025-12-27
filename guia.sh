#!/bin/bash

# Definición de Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

clear
echo -e "${CYAN}========================================================================${NC}"
echo -e "${CYAN}   🧪  LABORATORIO DISASTER RECOVERY & AUTOMATION (v4.0 Modular)      ${NC}"
echo -e "${CYAN}========================================================================${NC}"
echo ""

echo -e "${YELLOW}--- FASE 0: PRERREQUISITOS ---${NC}"
echo -e "1. Credenciales AWS configuradas en ${GRAY}~/.aws/credentials${NC}"
echo -e "2. Herramientas: Terraform, Ansible, PowerShell (pwsh), Zip."
echo ""

echo -e "${YELLOW}--- FASE 1: INFRAESTRUCTURA (Terraform) ---${NC}"
echo -e "${GRAY}Objetivo: Levantar Red, EC2 (Windows) y RDS (SQL Server).${NC}"
echo -e "3. Inicializar y Desplegar:"
echo -e "   ${GREEN}cd terraform${NC}"
echo -e "   ${GREEN}terraform init${NC}"
echo -e "   ${GREEN}terraform apply -auto-approve${NC}"
echo -e "   ${BLUE}> Nota: Tarda ~15 min. Genera inventory.ini y group_vars automáticamente.${NC}"
echo -e "   ${GREEN}cd ..${NC}"
echo ""

echo -e "${YELLOW}--- FASE 2: CONFIGURACIÓN BASE (Ansible) ---${NC}"
echo -e "${GRAY}Objetivo: Instalar IIS, ASP.NET y App v1.0.${NC}"
echo -e "4. Verificar conexión WinRM:"
echo -e "   ${GREEN}ansible -i ansible/inventory.ini windows -m win_ping${NC}"
echo -e "5. Desplegar App v1.0:"
echo -e "   ${GREEN}ansible-playbook -i ansible/inventory.ini ansible/playbooks/deploy_app.yml${NC}"
echo -e "   ${BLUE}> Validación: http://<IP_PUBLICA> (Debe salir en VERDE)${NC}"
echo ""

echo -e "${YELLOW}--- FASE 3: EL CAOS Y LA CURA (Orquestador) ---${NC}"
echo -e "${GRAY}Objetivo: Backup -> Update Fallido -> Detección -> Restauración Automática.${NC}"
echo -e "6. Generar Artefacto Malicioso (v2.0):"
echo -e "   ${GREEN}bash scripts/recrearZip.sh${NC}"
echo -e "7. Ejecutar el Orquestador Maestro:"
echo -e "   ${GREEN}pwsh scripts/orchestrator.ps1${NC}"
echo ""
echo -e "   ${CYAN}RESULTADO ESPERADO DEL ORQUESTADOR:${NC}"
echo -e "   1. ${GREEN}Backups Paralelos:${NC} Snapshot de RDS y Disco D: completados."
echo -e "   2. ${RED}Fallo Crítico:${NC} Ansible intenta desplegar v2.0 y falla."
echo -e "   3. ${RED}Detección:${NC} Identifica 'Script Malicioso' o 'Fallo de Migración'."
echo -e "   4. ${YELLOW}Auto-Healing:${NC} "
echo -e "      - Crea nueva RDS (lab-db-recovered)."
echo -e "      - Crea nuevo Disco EBS y sustituye al corrupto (Hot Swap)."
echo -e "      - Actualiza IP en inventory.ini."
echo -e "      - Ansible reconfigura web.config con el nuevo Endpoint."
echo -e "   5. ${GREEN}Éxito:${NC} El sistema vuelve a estar online con la v1.0 restaurada."
echo ""

echo -e "${YELLOW}--- FASE 4: VALIDACIÓN POST-MORTEM ---${NC}"
echo -e "8. Comprobar la web de nuevo:"
echo -e "   ${GREEN}http://<NUEVA_IP_PUBLICA>/${NC}"
echo -e "   ${BLUE}> Debe funcionar y mostrar datos (Conectado a lab-db-recovered).${NC}"
echo ""

echo -e "${RED}--- FASE 5: LIMPIEZA Y DRIFT (¡IMPORTANTE!) ---${NC}"
echo -e "${GRAY}Al restaurar, hemos cambiado la infraestructura real (Drift). Terraform ya no está sincronizado.${NC}"
echo -e "9. Destruir Laboratorio:"
echo -e "   ${GREEN}cd terraform && terraform destroy -auto-approve${NC}"
echo -e "   ${RED}⚠️ ATENCIÓN:${NC} Terraform NO borrará los recursos creados por el Orquestador:"
echo -e "      - La RDS 'lab-db-recovered'."
echo -e "      - El Volumen EBS restaurado."
echo -e "   ${GRAY}Debes borrarlos manualmente desde la consola de AWS para no incurrir en costes.${NC}"
echo ""

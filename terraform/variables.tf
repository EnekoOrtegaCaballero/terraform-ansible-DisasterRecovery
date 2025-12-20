variable "admin_password" {
  description = "Contraseña de administrador para la instancia Windows"
  type        = string
  sensitive   = true  # Esto evita que Terraform la muestre en los logs de consola
}

variable "region" {
  description = "Región de AWS"
  default     = "us-east-1"
}

variable "db_password" {
  description = "Contraseña maestra para la RDS SQL Server"
  type        = string
  sensitive   = true
}

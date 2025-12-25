# terraform/outputs.tf

# Esto le dice a Terraform: "Cuando termines, publica el ID de la instancia app_server"
output "ec2_instance_id" {
  value = aws_instance.app_server.id
}

# Esto le dice a Terraform: "Cuando termines, publica el nombre de la DB sql_db"
output "rds_identifier" {
  value = aws_db_instance.sql_db.identifier
}

#Añadir el ID del disco D
output "data_disk_id" {
  description = "ID del volumen EBS (Disco D:) para snapshots"
  value       = aws_ebs_volume.data_disk.id
}
output "region" {
  description = "Región de AWS"
  value       = var.region
}

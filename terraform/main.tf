terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- 1. DATOS DINÁMICOS (DATA SOURCES) ---

# A) Mi IP Pública actual (Detectada automáticamente)
data "http" "my_public_ip" {
  url = "http://checkip.amazonaws.com/"
}

# B) VPC y Subnets por defecto
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# C) AMI de Windows Server 2022 más reciente
data "aws_ami" "windows_2022" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

# --- 2. SEGURIDAD (SECURITY GROUPS) ---

# GRUPO A: Servidor Web (EC2)
resource "aws_security_group" "web_sg" {
  name        = "lab-web-sg"
  description = "Permite WinRM seguro y HTTP"
  vpc_id      = data.aws_vpc.default.id

  # Entrada: WinRM HTTPS (Gestión segura) - Solo desde TU IP actual
  ingress {
    description = "WinRM from my IP"
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    # chomp() elimina el salto de línea y añadimos /32 para cerrar el rango
    cidr_blocks = ["${chomp(data.http.my_public_ip.response_body)}/32"]
  }

  # Entrada: HTTP (Web App) - Abierto a todo el mundo (o puedes restringirlo a tu IP también)
  ingress {
    description = "HTTP Public Access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Entrada: RDP (Opcional para debug) - Solo desde TU IP actual
  ingress {
    description = "RDP from my IP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_public_ip.response_body)}/32"]
  }

  # Salida: Todo permitido
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# GRUPO B: Base de Datos (RDS)
# Chaining: Solo acepta tráfico si viene del Grupo de Seguridad Web (A)
resource "aws_security_group" "db_sg" {
  name        = "lab-db-sg"
  description = "Permite SQL Server solo desde el Servidor Web"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
}

# --- 3. COMPUTACIÓN (EC2) ---
resource "aws_instance" "app_server" {
  ami           = data.aws_ami.windows_2022.id
  instance_type = "t2.medium" 
  
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # Inyección del User Data (Recuerda tener user_data.ps1 en la misma carpeta)
  user_data = templatefile("user_data.ps1", {
    admin_password = var.admin_password
  })

  tags = {
    Name = "Win-AutoHeal-Lab"
  }
}

# --- 4. BASE DE DATOS (RDS) ---
resource "aws_db_instance" "sql_db" {
  identifier        = "lab-db-prod"
  engine            = "sqlserver-ex"
  engine_version    = "15.00"        
  instance_class    = "db.t3.micro"  
  allocated_storage = 20             
  username          = "adminSql"
  password          = var.db_password
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false     
  skip_final_snapshot    = true      

  tags = {
    Name = "ProductionDB"
  }
}

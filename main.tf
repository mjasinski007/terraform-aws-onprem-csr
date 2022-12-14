data "aws_region" "current" {}

# Retrieve my public IP address
data "http" "my_public_ip" {
    url = "http://ipv4.icanhazip.com"
}

# CSR AMI
data "aws_ami" "this" {
    owners      = ["aws-marketplace"]
    #owners      = ["679593333241"] # Cisco Systems
    most_recent = true

    filter {
        name   = "name"
        #values = var.csr_ami == "BYOL" ? [var.csr_ami_byol_ami] : [var.csr_ami_sec_ami]
        #values = var.prioritize == "price" ? ["cisco_CSR-17.03.06-BYOL-624f5bb1-7f8e-4f7c-ad2c-03ae1cd1c2d3ami-0d8ad992c259060ef"] : ["cisco_CSR-.17.3.3-SEC-dbfcb230-402e-49cc-857f-dacb4db08d34"]
        values = ["cisco_CSR-.16.12.06-BYOL-624f5bb1-7f8e-4f7c-ad2c-03ae1cd1c2d3"]
    }
}


## Generate Private-Key Pair
resource "tls_private_key" "onprem_csr_priv_key" {
    algorithm = "RSA"
    rsa_bits  = 4096
}

resource "aws_key_pair" "onprem_csr_key_pair" {
    key_name   = "OnPremCSR_KeyPair"       # Create a "myKey" to AWS!!
    public_key = tls_private_key.onprem_csr_priv_key.public_key_openssh
}

resource "local_file" "local_ssh_key" {
    filename = "${aws_key_pair.onprem_csr_key_pair.key_name}.pem"
    content = tls_private_key.onprem_csr_priv_key.private_key_pem
    file_permission = "0400"
}


# Running config template
data "template_file" "running_config" {
    template = file("${path.module}/running-config.tpl")

    vars = {
        admin_password = var.admin_password
        hostname       = var.csr_hostname
    }
}


# Create a Security Group for Cisco CSR Gig1
resource "aws_security_group" "gig1_sg" {
    vpc_id = var.vpc_id
    name   = "OnPremCSR GigabitEthernet1 Security Group"

    dynamic "ingress" {
        for_each = local.ingress_ports
        content {
            description = ingress.key
            from_port   = ingress.value.port
            to_port     = ingress.value.port
            protocol    = ingress.value.protocol
            cidr_blocks = ingress.value.cidr_blocks
        }
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = var.egress_cidr_blocks
    }

    tags = {
        Name = "OnPremCSR_Gig1_SG"
    }

    lifecycle {
        ignore_changes = [ingress, egress]
    }
}

# Create a Security Group for Cisco CSR Gig2
resource "aws_security_group" "gig2_sg" {
    vpc_id = var.vpc_id
    name   = "OnPremCSR GigabitEthernet2 Security Group"

    dynamic "ingress" {
        for_each = local.ingress_ports
        content {
            description = ingress.key
            from_port   = ingress.value.port
            to_port     = ingress.value.port
            protocol    = ingress.value.protocol
            cidr_blocks = ingress.value.cidr_blocks
        }
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = var.egress_cidr_blocks
    }

    tags = {
        Name = "OnPremCSR_Gig2_SG"
    }

    lifecycle {
        ignore_changes = [ingress, egress]
    }
}

# Create eni for CSR Gi1
resource "aws_network_interface" "csr_gig1" {
    description       = "OnPremCSR GigabitEthernet1"
    subnet_id         = var.gig1_subnet_id
    security_groups   = [aws_security_group.gig1_sg.id]
    source_dest_check = false

    tags = {
        Name = "OnPremCSR_Gig1_ENI"
    }
}

# Create eni for CSR Gi2
resource "aws_network_interface" "csr_gig2" {
    description       = "OnPremCSR GigabitEthernet2"
    subnet_id         = var.gig2_subnet_id
    security_groups   = [aws_security_group.gig2_sg.id]
    source_dest_check = false

    tags = {
        Name = "OnPremCSR_Gig2_ENI"
    }
}

# Allocate EIP for CSR Gi1
resource "aws_eip" "this" {
    vpc               = true
    network_interface = aws_network_interface.csr_gig1.id

    tags = {
        "Name" = "OnPremCSR-Gig1-EIP@${var.csr_hostname}"
    }
}

# Create CSR EC2 instance
resource "aws_instance" "this" {
    ami           = data.aws_ami.this.id
    instance_type = var.instance_type
    #key_name      = var.key_name
    key_name      = aws_key_pair.onprem_csr_key_pair.key_name

    network_interface {
        network_interface_id = aws_network_interface.csr_gig1.id
        device_index         = 0
    }

    network_interface {
        network_interface_id = aws_network_interface.csr_gig2.id
        device_index         = 1
    }

    user_data = local.csr_bootstrap

    tags = {
        Name = var.csr_hostname
    }

    lifecycle {
        ignore_changes = [ami]
    }
}
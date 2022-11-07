
data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

//Getting latest version of ubuntu
data "aws_ami" "latest_ubuntu" {
  owners      = ["137112412989"]
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-*"]
  }
}

//Creating VPCs
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "${var.env}-vpc"
  }
}

//Creating Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.env}-igw"
  }
}

// Creating Public Subnets
resource "aws_subnet" "public_subnets" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = element(var.public_subnet_cidrs, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.env}-public-${count.index + 1}"
  }
}

// Creating Route Table of Public Subnet
resource "aws_route_table" "public_subnets" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name = "${var.env}-route-public-subnets"
  }
}

//Public Route Table Association
resource "aws_route_table_association" "public_routes" {
  count          = length(aws_subnet.public_subnets[*].id)
  route_table_id = aws_route_table.public_subnets.id
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
}


// Creating Private Subnets
resource "aws_subnet" "private_subnets" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.private_subnet_cidrs, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "${var.env}-private-${count.index + 1}"
  }
}

// Key crating and downloading
resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "kp" {
  key_name   = "${var.env}-myKey" # Create a "myKey" to AWS!!
  public_key = tls_private_key.pk.public_key_openssh
}

resource "local_file" "ssh_key" {
  filename = "${aws_key_pair.kp.key_name}.pem"
  content  = tls_private_key.pk.private_key_pem

  provisioner "local-exec" {
    command     = "chmod 400 ${aws_key_pair.kp.key_name}.pem"
    interpreter = ["bash", "-c"]
  }
}

//Creating Public EC2 Instance
resource "aws_instance" "Public_EC2" {
  count                       = length(aws_subnet.public_subnets[*].id)
  ami                         = data.aws_ami.latest_ubuntu.id
  availability_zone           = data.aws_availability_zones.available.names[count.index]
  instance_type               = "t2.micro"
  subnet_id                   = element(aws_subnet.public_subnets[*].id, count.index)
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.allow_all.id]
  user_data                   = file("./userData/user_data.sh")

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "PublicUser"
    private_key = tls_private_key.pk.private_key_pem
    timeout     = "4m"
  }
  tags = {
    Name = "${var.env}-EC2-Public-${count.index + 1}"
  }
}

//Creating Private EC2 Instance
resource "aws_instance" "Private_EC2" {
  count                  = length(aws_subnet.private_subnets[*].id)
  ami                    = data.aws_ami.latest_ubuntu.id
  availability_zone      = data.aws_availability_zones.available.names[count.index]
  instance_type          = "t2.micro"
  subnet_id              = element(aws_subnet.private_subnets[*].id, count.index)
  vpc_security_group_ids = [aws_security_group.allow_only_ping.id]

  tags = {
    Name = "${var.env}-EC2-Private-${count.index + 1}"
  }
}


//Creating Security Group with dynamic ingress
resource "aws_security_group" "allow_all" {
  name        = "allow"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = ["80", "22", "443"]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "TCP"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  ingress {
    description = "ICMP for EC2"
    from_port   = 8
    to_port     = 0
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_tls_for_public_EC2"
  }
}

// Instance for testing
resource "aws_security_group" "allow_only_ping" {
  name        = "Allow only PING"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "ICMP for EC2"
    from_port   = 8
    to_port     = 0
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_only_ping"
  }
}

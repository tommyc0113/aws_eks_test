
# =================================================================================================
# =================================================================================================
# =================================================================================================

# VPC
module "vpc" {
  source           = "terraform-aws-modules/vpc/aws"
  version          = "5.1.1"
  name             = "eks_vpc"
  azs              = local.azs
  cidr             = local.cidr
  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  enable_dns_hostnames = "true"
  enable_dns_support   = "true"
  tags = {
    "TerraformManaged" = "true"
  }
}

# Security-Group (BastionHost)
module "BastionHost_SG" {
  source          = "terraform-aws-modules/security-group/aws"
  version         = "5.1.0"
  name            = "BastionHost_SG"
  description     = "BastionHost_SG"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = "false"

  ingress_with_cidr_blocks = [
    {
      from_port   = local.ssh_port
      to_port     = local.ssh_port
      protocol    = local.tcp_protocol
      description = "SSH"
      cidr_blocks = local.all_network
    },
    {
      from_port   = local.any_protocol
      to_port     = local.any_protocol
      protocol    = local.icmp_protocol
      description = "ICMP"
      cidr_blocks = local.cidr
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.all_network
    }
  ]
}

# BastionHost EIP
resource "aws_eip" "BastionHost_eip" {
  instance = aws_instance.BastionHost.id
  tags = {
    Name = "BastionHost_EIP"
  }
}

# BastionHost Key-Pair DataSource
data "aws_key_pair" "EC2-Key" {
  key_name = "EC2-key"
}

# BastionHost Instance
# EKS Cluster SG : data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id 
resource "aws_instance" "BastionHost" {
  ami                         = "ami-0ea4d4b8dc1e46212"
  instance_type               = "t2.micro"
  key_name                    = data.aws_key_pair.EC2-Key.key_name
  subnet_id                   = module.vpc.public_subnets[1]
  associate_public_ip_address = true
  vpc_security_group_ids      = [module.BastionHost_SG.security_group_id, data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id]
  depends_on                  = [module.eks]
  tags = {
    Name = "BastionHost_Instance"
  }
}

# Security-Group (NAT-Instance)
module "NAT_SG" {
  source          = "terraform-aws-modules/security-group/aws"
  version         = "5.1.0"
  name            = "NAT_SG"
  description     = "All Traffic"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = "false"

  ingress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.private_subnets[0]
    },
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.private_subnets[1]
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.all_network
    }
  ]
}

# NAT Instance ENI(Elastic Network Interface)
resource "aws_network_interface" "NAT_ENI" {
  subnet_id         = module.vpc.public_subnets[0]
  private_ips       = ["192.168.1.50"]
  security_groups   = [module.NAT_SG.security_group_id]
  source_dest_check = false

  tags = {
    Name = "NAT_Instance_ENI"
  }
}

# NAT Instance 
resource "aws_instance" "NAT_Instance" {
  ami           = "ami-00295862c013bede0"
  instance_type = "t2.micro"
  depends_on    = [aws_network_interface.NAT_ENI]

  network_interface {
    network_interface_id = aws_network_interface.NAT_ENI.id
    device_index         = 0
  }

  tags = {
    Name = "NAT_Instance"
  }
}

# NAT Instance ENI EIP
resource "aws_eip" "NAT_Instance_eip" {
  network_interface = aws_network_interface.NAT_ENI.id
  tags = {
    Name = "NAT_EIP"
  }
  depends_on = [aws_network_interface.NAT_ENI, aws_instance.NAT_Instance]
}

# Private Subnet Routing Table ( dest: NAT Instance ENI )
data "aws_route_table" "private_1" {
  subnet_id  = module.vpc.private_subnets[0]
  depends_on = [module.vpc]
}

data "aws_route_table" "private_2" {
  subnet_id  = module.vpc.private_subnets[1]
  depends_on = [module.vpc]
}

resource "aws_route" "private_subnet_1" {
  route_table_id         = data.aws_route_table.private_1.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.NAT_ENI.id
  depends_on             = [module.vpc, aws_instance.NAT_Instance]
}

resource "aws_route" "private_subnet_2" {
  route_table_id         = data.aws_route_table.private_2.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.NAT_ENI.id
  depends_on             = [module.vpc, aws_instance.NAT_Instance]
}

# =================================================================================================
# =================================================================================================
# =================================================================================================

/* 
  # Kubernetes 추가 Provider
  EKS Cluster 구성 후 초기 구성 작업을 수행하기 위한 Terraform Kubernetes Provider 설정 
  생성 된 EKS Cluster의 EndPoint 주소 및 인증정보등을 DataSource로 정의 후 Provider 설정 정보로 입력
 */

# AWS EKS Cluster Data Source
data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# AWS EKS Cluster Auth Data Source
data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# AWS EKS Cluster DataSource DOCS 
# - aws_eks_cluster      : https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster.html
# - aws_eks_cluster_auth : https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster_auth


provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Terraform EKS Module DOCS : https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  # EKS Cluster Setting
  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  # OIDC(OpenID Connect) 구성 
  enable_irsa = true

  # EKS Worker Node 정의 ( ManagedNode방식 / Launch Template 자동 구성 )
  eks_managed_node_groups = {
    EKS_Worker_Node = {
      instance_types = ["t3.small"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  # public-subnet(bastion)과 API와 통신하기 위해 설정(443)
  cluster_endpoint_public_access = true

  # K8s ConfigMap Object "aws_auth" 구성
  enable_cluster_creator_admin_permissions = true
}

// Private Subnet Tag ( AWS Load Balancer Controller Tag / internal )
resource "aws_ec2_tag" "private_subnet_tag" {
  for_each    = { for idx, subnet in module.vpc.private_subnets : idx => subnet }
  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

// Public Subnet Tag (AWS Load Balancer Controller Tag / internet-facing)
resource "aws_ec2_tag" "public_subnet_tag" {
  for_each    = { for idx, subnet in module.vpc.public_subnets : idx => subnet }
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

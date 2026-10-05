data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  availability_zone    = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  kubeconfig_parameter = "/${var.name}/kubeconfig"
}

# --- Network: one public subnet, no NAT gateway ---------------------------------
# The VPC CIDR must not overlap k3s defaults (pods 10.42.0.0/16, services 10.43.0.0/16).

resource "aws_vpc" "this" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "nodes" {
  name        = "${var.name}-nodes"
  description = "k3s nodes for the Jenkins troubleshooting lab"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-nodes" }
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.nodes.id
  description       = "Kubernetes API"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "All traffic between cluster nodes"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  description       = "Internet access for packages, images and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- IAM: EBS CSI driver, SSM Session Manager, kubeconfig parameter ---------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nodes" {
  name               = "${var.name}-nodes"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "kubeconfig_parameter" {
  statement {
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.kubeconfig.arn]
  }
}

resource "aws_iam_role_policy" "kubeconfig_parameter" {
  name   = "publish-kubeconfig"
  role   = aws_iam_role.nodes.id
  policy = data.aws_iam_policy_document.kubeconfig_parameter.json
}

resource "aws_iam_instance_profile" "nodes" {
  name = "${var.name}-nodes"
  role = aws_iam_role.nodes.name
}

# The server overwrites this value with its kubeconfig once k3s is ready.
resource "aws_ssm_parameter" "kubeconfig" {
  name  = local.kubeconfig_parameter
  type  = "SecureString"
  tier  = "Intelligent-Tiering"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- k3s nodes ------------------------------------------------------------------

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.server_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.nodes.name

  user_data = templatefile("${path.module}/templates/server.sh.tpl", {
    region               = var.region
    k3s_channel          = var.k3s_channel
    k3s_token            = random_password.k3s_token.result
    kubeconfig_parameter = local.kubeconfig_parameter
    project_tag          = var.name
    jenkins_values       = file("${path.module}/../helm/values-aws.yaml")
  })
  user_data_replace_on_change = true

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # Hop limit 2 lets pods (the EBS CSI driver) reach the instance metadata service.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.name}-server" }

  depends_on = [
    aws_route_table_association.public,
    aws_iam_role_policy.kubeconfig_parameter,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

resource "aws_instance" "agent" {
  count = var.agent_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.agent_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.nodes.name

  user_data = templatefile("${path.module}/templates/agent.sh.tpl", {
    k3s_channel = var.k3s_channel
    k3s_token   = random_password.k3s_token.result
    server_ip   = aws_instance.server.private_ip
  })
  user_data_replace_on_change = true

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.name}-agent-${count.index}" }
}

# --- Optional cost alert ----------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  count = var.budget_email == "" ? 0 : 1

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}

variable "name" {
  description = "Prefix for resource names and the Project tag."
  type        = string
  default     = "jenkins-lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for the subnet. Defaults to the region's first zone."
  type        = string
  default     = null
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API (port 6443). Use your own public IP, for example [\"203.0.113.10/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "Set at least one CIDR, and do not open the API to 0.0.0.0/0."
  }

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : try(cidrhost(c, 0) == split("/", c)[0], false)])
    error_message = "Each entry must be a network CIDR. For a single IP, add /32, for example \"203.0.113.10/32\"."
  }
}

variable "server_instance_type" {
  description = "Instance type for the k3s server, which also runs the Jenkins controller."
  type        = string
  default     = "t3.large"
}

variable "agent_count" {
  description = "Number of k3s agent nodes. Use at least 1 for the node failure scenario."
  type        = number
  default     = 1

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 3
    error_message = "agent_count must be between 0 and 3."
  }
}

variable "agent_instance_type" {
  description = "Instance type for k3s agent nodes."
  type        = string
  default     = "t3.small"
}

variable "use_spot" {
  description = "Run the nodes as one-time spot instances. Set to false for the presentation day."
  type        = bool
  default     = true
}

variable "k3s_channel" {
  description = "k3s release channel (stable, latest, or a minor such as v1.33)."
  type        = string
  default     = "stable"
}

variable "budget_email" {
  description = "If set, creates an account-wide monthly cost budget that emails this address at 80% of budget_limit_usd."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD."
  type        = number
  default     = 10
}

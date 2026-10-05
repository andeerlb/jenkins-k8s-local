output "server_public_ip" {
  description = "Public IP of the k3s server (Kubernetes API on port 6443)."
  value       = aws_instance.server.public_ip
}

output "server_instance_id" {
  description = "Instance ID of the k3s server."
  value       = aws_instance.server.id
}

output "agent_instance_ids" {
  description = "Instance IDs of the k3s agent nodes."
  value       = aws_instance.agent[*].id
}

output "kubeconfig_command" {
  description = "Writes the cluster kubeconfig once the server has published it."
  value       = "aws ssm get-parameter --region ${var.region} --name ${local.kubeconfig_parameter} --with-decryption --query Parameter.Value --output text > ~/.kube/${var.name}.yaml && chmod 600 ~/.kube/${var.name}.yaml"
}

output "server_shell_command" {
  description = "Opens a shell on the server through SSM Session Manager (needs the session-manager-plugin)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.server.id}"
}

output "leftover_volumes_command" {
  description = "Lists EBS volumes created by the CSI driver. Run it after destroy; the list should be empty."
  value       = "aws ec2 describe-volumes --region ${var.region} --filters Name=tag:Project,Values=${var.name} --query 'Volumes[].{id:VolumeId,state:State,size:Size}' --output table"
}

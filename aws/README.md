# Jenkins on k3s in AWS

A low-cost cluster for the troubleshooting labs, closer to a cloud setup than kind. OpenTofu creates a small VPC, one k3s server (which also runs the Jenkins controller), optional k3s agent nodes, an IAM role for the EBS CSI driver, and a CloudWatch log group for container logs. Jenkins stores its data on an EBS `gp3` volume, which enforces the requested size; kind's local-path volumes do not.

This is a lab, not a production setup: one public subnet, a single k3s server, and spot instances by default.

## What it creates

| Resource | Default | Notes |
|---|---|---|
| VPC + 1 public subnet + internet gateway | `10.100.0.0/16` | No NAT gateway |
| k3s server | 1× `t3.large` spot | Runs the Jenkins controller |
| k3s agents | 1× `t3.small` spot | Needed for the node failure scenario |
| Security group | port 6443 from `allowed_cidrs` only | No SSH; shell access through SSM Session Manager |
| IAM role | EBS CSI driver, SSM core, write the kubeconfig parameter, write container logs | |
| CloudWatch log group | `/jenkins-lab/containers`, 3-day retention | One stream per container; deleted by `tofu destroy` |
| SSM parameter | `/jenkins-lab/kubeconfig` | The server publishes its kubeconfig here |
| Budget (optional) | $10/month, alert at 80% | Only when `budget_email` is set; covers the whole account |

The bootstrap script on the server installs k3s, the EBS CSI driver, a default `gp3` StorageClass with volume expansion enabled, Fluent Bit (a DaemonSet that sends every container's log to CloudWatch), and Jenkins with [`../helm/values-aws.yaml`](../helm/values-aws.yaml) (5 GiB PVC, controller memory limit 2 GiB).

## Cost

With the defaults, expect roughly **US$0.05 per hour** while running: spot instances, EBS volumes, and public IPv4 addresses. CloudWatch charges per GB of logs ingested (about US$0.50/GB in us-east-1); this lab produces a few MB per day. Spot prices vary by region and time. Destroy the stack when you finish; a stopped lab should cost close to nothing.

## Prerequisites

- OpenTofu 1.6 or later
- AWS CLI with credentials for a lab account. Prefer an IAM user or SSO role over root account keys.
- `kubectl`
- The Session Manager plugin, for a shell on the nodes (below)

### Install the Session Manager plugin

The nodes have no SSH access. A shell on a node goes through AWS Systems Manager Session Manager, which the AWS CLI uses only when this plugin is installed.

Ubuntu or Debian (x86_64):

```sh
curl -fsSL https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb \
  -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
```

macOS (Homebrew):

```sh
brew install --cask session-manager-plugin
```

For other systems, see the [AWS installation guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Verify the installation:

```sh
session-manager-plugin --version
```

## Create

```sh
cd aws
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs to your IP
tofu init
tofu plan -out lab.tfplan
tofu apply lab.tfplan
```

The instances take a few minutes to install everything after `apply` finishes. Retrieve the kubeconfig once the server has published it (the parameter value is `pending` until then):

```sh
$(tofu output -raw kubeconfig_command)
export KUBECONFIG=~/.kube/jenkins-lab.yaml
kubectl get nodes
kubectl -n jenkins get pods,pvc
```

If something does not come up, open a shell on the server and read the bootstrap log:

```sh
$(tofu output -raw server_shell_command)
sudo tail -f /var/log/jenkins-lab-setup.log
```

The shell needs the Session Manager plugin on your machine; without it, `aws ssm start-session` fails with `SessionManagerPlugin is not found`. See [Install the Session Manager plugin](#install-the-session-manager-plugin).

## Access Jenkins

```sh
kubectl -n jenkins port-forward svc/jenkins 8080:8080
kubectl -n jenkins exec svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password && echo
```

Open <http://localhost:8080> and sign in as `admin`. The second command prints the admin password created by the chart.

## Container logs in CloudWatch

Fluent Bit runs on every node and sends each container's log to the `/jenkins-lab/containers` log group. Each container gets its own stream, named `<namespace>.<pod>.<container>`, for example `jenkins.jenkins-0.jenkins`. The streams remain after the pod is deleted or restarted, so the evidence survives: `kubectl logs` can only read logs that are still on the node.

Follow the Jenkins controller log:

```sh
$(tofu output -raw controller_logs_command)
```

Search all containers for an error, for example in the last hour:

```sh
aws logs filter-log-events --log-group-name /jenkins-lab/containers \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '"No space left on device"' \
  --query 'events[].[logStreamName,message]' --output text
```

In the AWS console, **CloudWatch → Logs Insights** queries the same log group:

```
fields @timestamp, @logStream, log
| filter log like /No space left on device/
| sort @timestamp desc
```

New logs reach CloudWatch within a few seconds. If nothing arrives, check the Fluent Bit pods: `kubectl -n logging logs daemonset/fluent-bit`.

## Labs

The [troubleshooting labs](../README.md#troubleshooting-labs) work on this cluster as well as on kind. [Controller disk is full](../troubleshooting/controller-disk-full/README.md) needs this setup, because it depends on EBS enforcing the PVC size.

## Your IP changed

The Kubernetes API accepts connections only from `allowed_cidrs`. Update `terraform.tfvars` and run `tofu plan` and `tofu apply` again; only the security group rule changes.

## Destroy

The EBS volume behind the Jenkins PVC is created by Kubernetes, not by OpenTofu, so `tofu destroy` does not know about it. Delete it through Kubernetes first, while the cluster is still running:

```sh
helm uninstall jenkins -n jenkins
kubectl -n jenkins delete pvc --all
kubectl get pv   # wait until no gp3 volumes remain

tofu destroy
aws ec2 describe-volumes --filters Name=tag:Project,Values=jenkins-lab \
  --query 'Volumes[].{id:VolumeId,state:State,size:Size}' --output table
```

The last command should list no volumes. Delete any that remain with `aws ec2 delete-volume --volume-id <id>`.

## Spot interruptions

AWS can reclaim a spot instance at any time. If the server is reclaimed, the cluster and Jenkins are gone; run `tofu apply` again to replace it, then delete the orphaned Jenkins volume as described above. For a live presentation, set `use_spot = false`.

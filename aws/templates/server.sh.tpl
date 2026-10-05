#!/bin/bash
# k3s server bootstrap: k3s, EBS CSI driver, gp3 StorageClass, Jenkins.
# Progress: /var/log/jenkins-lab-setup.log
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-lab-setup.log) 2>&1

IMDS_TOKEN=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

# local-storage is disabled so PVCs use EBS, which enforces the requested size.
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL='${k3s_channel}' K3S_TOKEN='${k3s_token}' sh -s - server \
  --tls-san "$PUBLIC_IP" \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --write-kubeconfig-mode 600

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 5; done

# Publish the kubeconfig early, so the cluster is reachable even if a later step fails.
snap install aws-cli --classic
sed "s/127.0.0.1/$PUBLIC_IP/" "$KUBECONFIG" > /root/kubeconfig-public.yaml
/snap/bin/aws ssm put-parameter \
  --region '${region}' \
  --name '${kubeconfig_parameter}' \
  --type SecureString \
  --tier Intelligent-Tiering \
  --overwrite \
  --value file:///root/kubeconfig-public.yaml
rm -f /root/kubeconfig-public.yaml

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add jenkins https://charts.jenkins.io
helm repo update

# The Project tag lets you find CSI-created volumes that outlive the cluster.
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.region='${region}' \
  --set controller.extraVolumeTags.Project='${project_tag}' \
  --wait --timeout 10m

kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
YAML

# Fluent Bit ships every container log to CloudWatch, one stream per container.
# Installed before Jenkins so the controller's startup log is captured.
cat > /root/fluent-bit-values.yaml <<'YAML'
config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
  outputs: |
    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.*
        region              ${region}
        log_group_name      ${log_group}
        log_stream_template $kubernetes['namespace_name'].$kubernetes['pod_name'].$kubernetes['container_name']
        log_stream_prefix   unknown.
        auto_create_group   false
YAML

helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace logging --create-namespace \
  --values /root/fluent-bit-values.yaml \
  --wait --timeout 5m

mkdir -p /root/jenkins
cat > /root/jenkins/values.yaml <<'YAML'
${jenkins_values}
YAML

helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  --values /root/jenkins/values.yaml \
  --wait --timeout 15m

echo "jenkins-lab setup finished"

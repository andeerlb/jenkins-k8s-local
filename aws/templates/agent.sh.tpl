#!/bin/bash
# k3s agent bootstrap. The agent keeps retrying until the server is up.
# Progress: /var/log/jenkins-lab-setup.log
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-lab-setup.log) 2>&1

curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL='${k3s_channel}' K3S_URL='https://${server_ip}:6443' K3S_TOKEN='${k3s_token}' sh -s - agent

echo "jenkins-lab agent setup finished"

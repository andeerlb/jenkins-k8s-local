# Jenkins on a local Kubernetes cluster

A [kind](https://kind.sigs.k8s.io/) cluster with two workers and Jenkins installed using the [official Helm chart](https://charts.jenkins.io/). The controller coordinates jobs. The Kubernetes plugin creates an agent pod for each run and removes it when the run finishes. Kubernetes workers are cluster nodes; Jenkins agents are pods running on those nodes.

## Prerequisites

- Docker running
- `kind`, `kubectl`, and `helm` installed
- Enough resources for the controller and agents (start with at least 4 CPUs and 8 GiB of available RAM)

## Create the cluster and install Jenkins

Run these commands from the repository root:

```sh
kind create cluster --name jenkins-local --config kind.yaml
kubectl config current-context
kubectl get nodes
kubectl get storageclass

helm repo add jenkins https://charts.jenkins.io
helm repo update
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  --values helm/values.yaml \
  --wait --timeout 10m

kubectl -n jenkins get pods,pvc
helm get notes jenkins -n jenkins
```

The expected context is `kind-jenkins-local`. Check it before running the Helm command to avoid installing Jenkins in another cluster. The chart generates the initial password; `helm get notes` shows how to retrieve it.

## Access Jenkins

In another terminal, run:

```sh
kubectl -n jenkins port-forward svc/jenkins 8080:8080
```

Open <http://localhost:8080> and sign in with the `admin` username and the password shown in the Helm notes.

## Test three concurrent agents

In the UI, create a **Pipeline** job, select **Pipeline script from SCM**, enter this repository's URL once it has a remote that Jenkins can access, and use `Jenkinsfile` as the script path. To test locally, create a **Pipeline** job, select **Pipeline script**, and paste the contents of `Jenkinsfile`.

Watch the pods during the build:

```sh
kubectl -n jenkins get pods -w
```

The three `parallel` branches request three agents. How many run at the same time depends on the available CPU and memory. Agent pods are temporary; the controller stores its configuration and jobs on the PVC.

To run Flutter or Android jobs, replace the example with an agent image that includes Flutter, Java, and the Android SDK. iOS builds require a macOS agent outside this Linux cluster.

## Troubleshooting labs

- [Agent image cannot be pulled](troubleshooting/image-pull/README.md)
- [Agent pod cannot be scheduled](troubleshooting/insufficient-resources/README.md)
- [Project checkout fails after the agent connects](troubleshooting/scm-checkout/README.md)
- [Controller lacks permission to create agent pods](troubleshooting/rbac/README.md)
- [Agent runs out of memory](troubleshooting/agent-oom/README.md)
- [Agent pod egress blocked by a NetworkPolicy](troubleshooting/network-policy/README.md)
- [Agent directed to the wrong Jenkins tunnel endpoint](troubleshooting/wrong-agent-endpoint/README.md)

## Remove Jenkins

```sh
helm uninstall jenkins -n jenkins
```

The PVC may remain after `helm uninstall`. `kind delete cluster --name jenkins-local` removes the local cluster and its data, including the Jenkins data stored in it.

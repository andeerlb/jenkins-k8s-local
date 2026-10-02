# Agent pod remains Pending because no node has enough memory

## Incident

Jenkins requests an agent pod, but the scheduler cannot place it on any worker. The pod stays `Pending` and the Pipeline waits. A new build image or resource request can cause this even when existing pods keep running.

Use the [main setup](../../README.md) and confirm that `kubectl config current-context` is `kind-jenkins-local`. On this local cluster, each kind node currently reports about 31 GiB allocatable memory; the lab requests 64 GiB. Check your own nodes before running it:

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,MEMORY:.status.allocatable.memory
```

If a node has at least 64 GiB allocatable memory, raise the request in the example above that value. Create a separate Jenkins **Pipeline** job with **Pipeline script**.

## Reproduce

```groovy
podTemplate(yaml: '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    troubleshooting.jenkins.io/scenario: insufficient-resources
spec:
  containers:
    - name: jnlp
      image: jenkins/inbound-agent
      resources:
        requests:
          memory: 64Gi
''', podRetention: always()) {
  node(POD_LABEL) {
    stage('Build') {
      sh 'hostname'
    }
  }
}
```

Run the job. Jenkins should create an agent pod, but no node should accept it. Record the pod name while the job is waiting; the plugin may eventually stop waiting and clean up.

## Investigate before fixing

```sh
kubectl -n jenkins get pods -l troubleshooting.jenkins.io/scenario=insufficient-resources -o wide
kubectl -n jenkins describe pod POD_NAME
kubectl get nodes -o custom-columns=NAME:.metadata.name,MEMORY:.status.allocatable.memory
kubectl -n jenkins get events --sort-by=.metadata.creationTimestamp
```

Look for `FailedScheduling` and `Insufficient memory` in the pod events. Compare the pod's **Requests** with each node's **Allocatable** memory. A pod in `Pending` has no `jnlp` container log yet: scheduling failed before container startup. In a real incident, also check node taints, affinity, quotas, and current allocations; the scheduler message tells you which constraint actually blocked this pod.

## Fix and verify

Reduce the request to a value the nodes can accommodate, for example `256Mi`, then start a new build. The new pod should move from `Pending` to `Running`, connect to Jenkins, and execute `hostname`. Remove retained lab pods after collecting their events:

```sh
kubectl -n jenkins delete pods -l troubleshooting.jenkins.io/scenario=insufficient-resources
```

## Presentation point

The Pipeline and the agent image may both be correct. The failure is at **Kubernetes scheduling**, which is visible in the pod events.

## References

- [Kubernetes: assigning pods to nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Kubernetes: resource management for pods](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

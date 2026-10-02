# Agent cannot connect: NetworkPolicy blocks pod egress

## Scenario

The Kubernetes plugin creates an agent pod, but its `jnlp` container cannot connect back to the Jenkins controller. Jenkins waits for the agent and the Pipeline does not reach its `sh` step. This lab uses an egress `NetworkPolicy` to reproduce a network failure while leaving the controller pod and other workloads alone.

Use the cluster and Jenkins installation described in the [main README](../../README.md). Run commands from the repository root. Confirm that `kubectl config current-context` returns `kind-jenkins-local`. kind supports NetworkPolicy out of the box starting with version 0.24.0; check `kind version` if the policy has no effect. The policy is namespaced, so it must be created in the namespace where the agent pods run. This guide assumes `jenkins`.

## Simulate the failure

First, run a normal Pipeline job to confirm an agent can connect. Then create a separate **Pipeline** job using **Pipeline script** and paste this script. The label gives the policy a precise target. `podRetention(always())` keeps the failed pod available for inspection; delete it during cleanup.

```groovy
podTemplate(
  yaml: '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    troubleshooting.jenkins.io/scenario: blocked-egress
spec: {}
''',
  podRetention: always()
) {
  node(POD_LABEL) {
    stage('Verify agent connection') {
      sh 'hostname'
    }
  }
}
```

Run this job once without the policy to establish a working baseline. After it succeeds, remove that retained baseline pod so later log commands show only the failed attempt:

```sh
kubectl -n jenkins delete pods -l troubleshooting.jenkins.io/scenario=blocked-egress
```

Then apply the policy below. It allows DNS queries to pods in `kube-system` on port 53 and blocks other egress from the labeled agent pods, including the connection to Jenkins. The policy does not select the controller.

```sh
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: troubleshooting-block-agent-egress
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      troubleshooting.jenkins.io/scenario: blocked-egress
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
YAML
```

Start the job again. The pod should be created, but its agent should not become online. The exact error depends on the connection mode and timing; expect repeated connection attempts, a timeout, or an agent connection failure. A pod may be `Running` while its Jenkins agent is offline.

## Investigate

```sh
kubectl -n jenkins get networkpolicy troubleshooting-block-agent-egress -o yaml
kubectl -n jenkins get networkpolicies
kubectl -n jenkins get pods -l troubleshooting.jenkins.io/scenario=blocked-egress -o wide
kubectl -n jenkins describe pods -l troubleshooting.jenkins.io/scenario=blocked-egress
kubectl -n jenkins logs -l troubleshooting.jenkins.io/scenario=blocked-egress -c jnlp --prefix --max-log-requests=10
kubectl -n jenkins get svc,endpoints
```

Compare the `jnlp` log with the Pipeline console output. Check whether the pod was scheduled and the container started before diagnosing connectivity. Inspect the `JENKINS_URL` and `JENKINS_TUNNEL` values in the pod description, without copying the agent secret into notes. Confirm that the controller Service has endpoints. If DNS also fails, inspect CoreDNS and the DNS allowance in the policy; a blocked DNS lookup is a different symptom from a resolved address followed by a connection timeout.

`NetworkPolicy` rules are additive. Another policy that permits egress from these same agent pods can make this experiment ineffective. If the agent still connects, inspect all policies in `jenkins` and confirm the pod has the selected label. Also verify that the kind cluster was created with a version that enforces NetworkPolicy.

## Clean up

```sh
kubectl -n jenkins delete networkpolicy troubleshooting-block-agent-egress
kubectl -n jenkins delete pods -l troubleshooting.jenkins.io/scenario=blocked-egress
```

Run the job again to verify that a new agent connects and executes `hostname`.

## References

- [Kubernetes NetworkPolicy behavior](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kind 0.24.0 release notes](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0)
- [Jenkins Kubernetes plugin pod templates](https://plugins.jenkins.io/kubernetes/)

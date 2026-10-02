# Agent cannot connect: wrong Jenkins tunnel endpoint

## Scenario

The Kubernetes plugin creates an agent pod, but the agent is directed to the wrong TCP endpoint for the Jenkins controller. The pod can run and reach the cluster network, yet the Jenkins agent remains offline. This simulates an incorrect hostname or port in the Kubernetes cloud configuration.

Use the cluster and Jenkins installation described in the [main README](../../README.md). Run commands from the repository root. Confirm that `kubectl config current-context` returns `kind-jenkins-local`. This lab assumes the chart's default TCP agent connection mode, with WebSocket disabled. If WebSocket is enabled, the agent uses the Jenkins HTTP(S) URL instead of the TCP tunnel, so this tunnel exercise will not reproduce the failure.

## Simulate the failure

First, run the repository's `Jenkinsfile` as a baseline and confirm that its agents connect. In Jenkins, open **Manage Jenkins → Clouds → Kubernetes** (the menu wording may vary by version). Record the current **Jenkins Tunnel** value. Check the controller and agent Services before editing the cloud:

```sh
kubectl -n jenkins get svc
kubectl -n jenkins get endpoints
```

Set **Jenkins Tunnel** to `127.0.0.1:59999` and save. For an agent pod, `127.0.0.1` is the pod's own network namespace, where no Jenkins listener is expected on port 59999. Leave the Kubernetes API URL and Jenkins URL unchanged so the controller can still create pods and the agent can still discover Jenkins. Start the Pipeline again.

Expect the agent pods to start but fail to become online. The `jnlp` log should show failed connection attempts to the configured tunnel endpoint. The precise log text depends on the agent image and plugin versions. The Pipeline may eventually report an agent connection timeout, and the plugin may remove failed pods; collect logs while the job is running.

## Investigate

```sh
kubectl -n jenkins get pods -o wide
kubectl -n jenkins describe pod POD_NAME
kubectl -n jenkins logs POD_NAME -c jnlp
kubectl -n jenkins get svc,endpoints
```

Replace `POD_NAME` with an agent pod name from the first command. In the pod description, compare `JENKINS_URL` and `JENKINS_TUNNEL` with the Kubernetes cloud settings and the actual Services. Do not copy `JENKINS_SECRET` into notes. Check whether the pod was scheduled and the `jnlp` container started. A `Pending` pod or an image pull failure is a different problem from an agent that starts but cannot connect.

The key finding should be that the tunnel points to `127.0.0.1:59999`, while the controller's agent listener is exposed by a Kubernetes Service. A failed connection to that address explains why the pod exists but Jenkins cannot use it as a node.

## Clean up

Restore the recorded **Jenkins Tunnel** value and save the Kubernetes cloud configuration. If the field was originally empty, clear it again rather than guessing a Service name. Run the Pipeline once more and confirm that the agents connect and the `hostname` steps execute. If Jenkins configuration is managed by the Helm chart, a later chart reconciliation may also restore the original value; verify the cloud settings before repeating the experiment.

## References

- [Jenkins Kubernetes plugin agent connection](https://plugins.jenkins.io/kubernetes/)
- [Jenkins Helm chart agent settings](https://github.com/jenkinsci/helm-charts/blob/main/charts/jenkins/VALUES.md)

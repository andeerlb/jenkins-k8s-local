# Agent pod cannot pull its image

## Incident

The Pipeline waits for an agent. Jenkins created a pod, but the `jnlp` container never started. The Kubernetes pod shows `ErrImagePull` or `ImagePullBackOff`. In a project, this can follow a renamed image tag, a private registry credential change, or a registry outage. This exercise reproduces the first cause.

Use the [main setup](../../README.md) and confirm that `kubectl config current-context` is `kind-jenkins-local`. Create a separate Jenkins **Pipeline** job with **Pipeline script**. Keep the repository's main `Jenkinsfile` as a working baseline.

## Reproduce

Run the normal Pipeline once to confirm an agent connects. Then paste this script into the lab job. The intentionally nonexistent tag affects only this pod template.

```groovy
podTemplate(yaml: '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    troubleshooting.jenkins.io/scenario: image-pull
spec:
  containers:
    - name: jnlp
      image: jenkins/inbound-agent:tag-does-not-exist-for-lab
''', podRetention: always()) {
  node(POD_LABEL) {
    stage('Build') {
      sh 'hostname'
    }
  }
}
```

Start the lab job and inspect the pod while Jenkins is waiting. The retention setting is intended to leave the failed pod available; still capture its name and events promptly.

## Investigate before fixing

```sh
kubectl -n jenkins get pods -l troubleshooting.jenkins.io/scenario=image-pull -w
kubectl -n jenkins describe pod POD_NAME
kubectl -n jenkins get pod POD_NAME -o jsonpath='{.spec.containers[*].image}'
kubectl -n jenkins get events --sort-by=.metadata.creationTimestamp
```

Replace `POD_NAME` with the new agent pod. In `describe`, look at **State**, **Reason**, and **Events**. A `Failed to pull image` event identifies a startup problem; there may be no useful `jnlp` log because the container never ran. Compare the requested image with the configured pod template. If the image exists but is private, investigate `imagePullSecrets` and registry access instead of changing tags. Confirm that the controller pod is healthy and that another job can launch an agent.

## Fix and verify

Change the image to a valid `jenkins/inbound-agent` tag, or remove the `image` override to use the chart's agent image. Start a **new** build: changing the job does not alter an already created pod. The new pod should pull its image, its agent should connect, and `hostname` should run. Delete retained lab pods after collecting evidence:

```sh
kubectl -n jenkins delete pods -l troubleshooting.jenkins.io/scenario=image-pull
```

## Presentation point

The job is waiting for an agent, but the fault is **before agent connection**. The decisive evidence is in Kubernetes pod events, not the Jenkins Pipeline log.

## References

- [Kubernetes pod debugging](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Jenkins Kubernetes plugin](https://plugins.jenkins.io/kubernetes/)

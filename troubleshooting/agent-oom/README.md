# Agent runs out of memory

## Incident

A Pipeline starts, then its agent disappears or a command ends with a memory related failure. Kubernetes may report `OOMKilled` when a container exceeds its memory limit. This can happen after adding a memory intensive build step or lowering an agent container's limit. This lab demonstrates the second case with an intentionally tiny limit, which makes the failure easier to reproduce.

Use the [main setup](../../README.md) and a separate Jenkins **Pipeline** job with **Pipeline script**. The normal `Jenkinsfile` remains the baseline. This exercise sets a 32 MiB memory limit on the Java based `jnlp` container, far below what it needs to start. The agent should fail during startup; it may never reach the `sh` step. This is an **agent memory limit** incident, not a Java compilation error.

## Reproduce

```groovy
podTemplate(yaml: '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    troubleshooting.jenkins.io/scenario: agent-oom
spec:
  containers:
    - name: jnlp
      image: jenkins/inbound-agent
      resources:
        requests:
          memory: 16Mi
        limits:
          memory: 32Mi
''', podRetention: always()) {
  node(POD_LABEL) {
    stage('Build') {
      sh 'hostname'
    }
  }
}
```

Run the job and capture the pod name. The request is set below the limit because the chart's normal agent template requests more memory than this lab allows. Depending on startup timing, the pod can show repeated restarts, `CrashLoopBackOff`, or a failed container with `OOMKilled` as its last termination reason.

## Investigate before fixing

```sh
kubectl -n jenkins get pods -l troubleshooting.jenkins.io/scenario=agent-oom -w
kubectl -n jenkins describe pod POD_NAME
kubectl -n jenkins get pod POD_NAME -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
kubectl -n jenkins logs POD_NAME -c jnlp --previous
kubectl -n jenkins get events --sort-by=.metadata.creationTimestamp
```

Look for `OOMKilled`, exit code `137`, and the `32Mi` memory limit in the pod description. The previous container log may be empty if the process was killed early. Compare the failure with a baseline agent pod using the normal image and resource settings. If the agent stays online but a build command fails, inspect the process and container used for that command; an exit code alone does not prove the whole pod was OOM killed.

## Fix and verify

Remove the artificial request and limit or set values that accommodate the agent and workload, then run a new build. Confirm that the agent connects and runs `hostname`. In a real incident, use observed memory usage and build requirements to choose requests and limits; simply raising the limit may hide a build memory leak. Remove retained lab pods after collecting evidence:

```sh
kubectl -n jenkins delete pods -l troubleshooting.jenkins.io/scenario=agent-oom
```

## Presentation point

The pod was created and the image was available, but the **running container** lacked memory. `kubectl describe pod` and container termination state identify the failure stage.

## References

- [Kubernetes memory resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes OOM debugging](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)

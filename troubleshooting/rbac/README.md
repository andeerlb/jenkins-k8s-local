# Controller cannot create agent pods because of RBAC

## Incident

Jenkins requests an agent, but the Kubernetes API rejects the controller's pod creation request. No new agent pod appears. In a real cluster, this can follow a service account change, a lost RoleBinding, or a deployment into a namespace where the controller lacks permissions.

Use only the isolated kind cluster from the [main setup](../../README.md). This lab temporarily changes the Helm managed `jenkins-schedule-agents` RoleBinding in the `jenkins` namespace, affecting every new agent requested by this controller. Finish or stop other builds before starting. The installed chart here uses the `jenkins` ServiceAccount, the `jenkins-schedule-agents` Role, and the RoleBinding of the same name. Check those names before changing anything.

## Reproduce

First, run the normal `Jenkinsfile` to confirm a working baseline. Capture the binding and verify the controller's permission:

```sh
kubectl -n jenkins get rolebinding jenkins-schedule-agents -o yaml
kubectl auth can-i create pods --as=system:serviceaccount:jenkins:jenkins -n jenkins
```

The permission check should return `yes`. Temporarily change the binding to a different, unused ServiceAccount name. The Role remains intact, but the controller loses its grant.

```sh
kubectl -n jenkins patch rolebinding jenkins-schedule-agents --type=merge \
  -p '{"subjects":[{"kind":"ServiceAccount","name":"troubleshooting-no-access","namespace":"jenkins"}]}'
kubectl auth can-i create pods --as=system:serviceaccount:jenkins:jenkins -n jenkins
```

The second permission check should return `no`. Start a new Pipeline build. The request for an agent should fail without creating a new pod.

## Investigate before fixing

```sh
kubectl -n jenkins get pods -w
kubectl -n jenkins logs jenkins-0 -c jenkins --since=10m
kubectl -n jenkins get rolebinding jenkins-schedule-agents -o yaml
kubectl -n jenkins get role jenkins-schedule-agents -o yaml
kubectl auth can-i create pods --as=system:serviceaccount:jenkins:jenkins -n jenkins
```

Look for an API `Forbidden` error in the controller or Pipeline logs. Compare the controller pod's ServiceAccount, the RoleBinding subject, and the Role's `pods` permissions. Because the API rejected the create request, there is no failed agent pod to inspect with `kubectl describe pod`. If a pod does appear, investigate that pod instead: this is a different failure stage.

## Restore and verify

```sh
kubectl -n jenkins patch rolebinding jenkins-schedule-agents --type=merge \
  -p '{"subjects":[{"kind":"ServiceAccount","name":"jenkins","namespace":"jenkins"}]}'
kubectl auth can-i create pods --as=system:serviceaccount:jenkins:jenkins -n jenkins
```

The permission check should return `yes`. Run a new Pipeline build and confirm the agent pod is created and connects. This restores the binding subject used by the chart in this repository; if you changed the binding beforehand, restore the original subject you recorded instead.

## Presentation point

When there is **no agent pod**, start with the controller and Kubernetes API permissions. Pod logs cannot help until a pod exists.

## References

- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Jenkins Kubernetes plugin](https://plugins.jenkins.io/kubernetes/)

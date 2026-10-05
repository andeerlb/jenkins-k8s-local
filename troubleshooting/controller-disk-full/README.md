# Controller disk is full

## Incident

Builds start failing in ways that look unrelated: a build cannot be recorded, a console log stops, or saving a job configuration returns an error. Kubernetes reports the controller pod as `Running`. The cause is the `JENKINS_HOME` volume: build history, logs, and artifacts grew until the PVC had no free space. This lab fills the volume with a single file so the failure is quick and the cleanup is obvious.

Use the [AWS setup](../../aws/README.md). Its Jenkins PVC is a 5 GiB EBS `gp3` volume, and EBS enforces that size. **Do not run this lab on kind**: kind's local-path volumes are directories on the host and do not enforce the PVC size, so `df` inside the pod reports the host disk, and filling it fills your machine.

## Reproduce

Run the repository's `Jenkinsfile` once to confirm a working baseline. Then check the volume. The size should be close to 5 GiB, not the size of a whole disk:

```sh
kubectl -n jenkins get pvc jenkins
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

If `df` reports far more than 5 GiB, stop: you are not on an EBS volume. Otherwise fill all the free space with one file:

```sh
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c \
  'fallocate -l "$(df --output=avail -B1 /var/jenkins_home | tail -1)" /var/jenkins_home/troubleshooting-fill'
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

`df` should now show `Use%` at or near 100%. Run the Pipeline again. The exact symptom depends on what Jenkins tries to write first: the build may fail to start, fail with `No space left on device` in its log, or leave an incomplete record. Saving a configuration page can also fail.

## Investigate before fixing

```sh
kubectl -n jenkins get pods
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'du -xsh /var/jenkins_home/* 2>/dev/null | sort -h | tail'
kubectl -n jenkins logs jenkins-0 -c jenkins --since=15m | grep -i -E 'no space|IOException'
kubectl -n jenkins get pvc jenkins -o jsonpath='{.status.capacity.storage}{"\n"}'
```

The pod stays `Running` and its probes may keep passing: Kubernetes does not treat a full volume as a pod failure. `df` shows the volume is full, and `du` shows what is using it. In this lab the largest entry is `troubleshooting-fill`; in a real incident it is usually `jobs/*/builds` (build history and logs) or archived artifacts. Under **Manage Jenkins → Nodes**, the built-in node may also show a low disk space warning.

## Fix and verify

**Free the space.** This is the immediate fix:

```sh
kubectl -n jenkins exec jenkins-0 -c jenkins -- rm /var/jenkins_home/troubleshooting-fill
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

Run the Pipeline again and confirm that it completes.

**Optional: expand the volume.** The `gp3` StorageClass allows expansion, so the PVC can grow while the controller runs:

```sh
kubectl -n jenkins patch pvc jenkins -p '{"spec":{"resources":{"requests":{"storage":"8Gi"}}}}'
kubectl -n jenkins get pvc jenkins -w
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

Wait until the PVC capacity and `df` both show the new size. Expansion is one way only: a volume cannot shrink, and EBS limits how often a volume can be modified. Set `persistence.size` in [`helm/values-aws.yaml`](../../helm/values-aws.yaml) to the new size before the next `helm upgrade`, or the chart will try to shrink the PVC and fail.

**Prevent it.** More space only delays the next incident. Limit build history on each job, for example in a scripted Pipeline:

```groovy
properties([buildDiscarder(logRotator(numToKeepStr: '20'))])
```

Move large artifacts to external storage instead of archiving them on the controller, and alert on volume usage (for example, the kubelet metric `kubelet_volume_stats_available_bytes`).

## Presentation point

Kubernetes reported a healthy pod while Jenkins could not write. The evidence is **inside the volume**, found with `df` and `du`, not in pod status or events. Expanding the volume fixes the symptom; retention fixes the cause.

## References

- [Kubernetes: expanding persistent volume claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
- [Amazon EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [Jenkins Pipeline: build discarder](https://www.jenkins.io/doc/pipeline/steps/workflow-multibranch/#properties-set-job-properties)

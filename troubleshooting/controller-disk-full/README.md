# Controller disk is full

## Incident

Someone selects **Build Now** and nothing happens: no new build appears, no agent pod starts, and there is no console log to read. Or a build that compiled successfully fails while archiving its artifacts. Saving a job configuration can also fail. Kubernetes reports the controller pod as `Running`. The cause is the `JENKINS_HOME` volume: build history, logs, and artifacts grew until the PVC had no free space. This lab fills the volume with a single file so the failure is quick and the cleanup is obvious.

Use the [AWS setup](../../aws/README.md). Its Jenkins PVC is a 5 GiB EBS `gp3` volume, and EBS enforces that size. **Do not run this lab on kind**: kind's local-path volumes are directories on the host and do not enforce the PVC size, so `df` inside the pod reports the host disk, and filling it fills your machine.

## Reproduce

### Create the baseline job

The lab uses one job before and after breaking the volume. In Jenkins:

1. Select **New Item**, name it `baseline`, choose **Pipeline**, and select **OK**.
2. Under **Pipeline**, set **Definition** to **Pipeline script**.
3. Paste the contents of the repository's [`Jenkinsfile`](../../Jenkinsfile) into **Script** and select **Save**.
4. Select **Build Now**.

Watch the agent pods while it runs:

```sh
kubectl -n jenkins get pods -o wide -w
```

Three agent pods should start, run for about 30 seconds, and be removed. The build should finish with **SUCCESS**, and each stage should print its pod name. The first build can take longer while the node pulls the agent image. If this build fails, fix the environment before continuing: the lab needs a working baseline.

The lab has two scenarios. In the first, the volume is already full when a build is requested. In the second, the volume fills while a build is running. Run them separately, and clean up between them as described in [Fix and verify](#fix-and-verify).

### Scenario 1: the volume is full before the build

Check the volume. The size should be close to 5 GiB, not the size of a whole disk:

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

`fallocate` may report `No space left on device` and exit with code 1. That is expected: the filesystem keeps some space for its own metadata, so the last part of the allocation fails, but the file still takes almost all the space. `df` should now show `Use%` at 100%.

Open the `baseline` job and select **Build Now** again. **No new build appears**: the build list still shows only the earlier builds, and no agent pod starts. Before a build runs, Jenkins must write its build number and create the build directory under `jobs/baseline/builds/`, which is also where the console log would go. That write fails, so the build is never created and there is no console log for it.

### Scenario 2: the volume fills during the build

A common real cause is archived artifacts: the agent builds a file and `archiveArtifacts` copies it to the controller, into `JENKINS_HOME`. This scenario leaves about 200 MiB free, then runs a build that archives a 300 MB file.

Leave about 200 MiB free:

```sh
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c \
  'fallocate -l "$(( $(df --output=avail -B1 /var/jenkins_home | tail -1) - 200*1024*1024 ))" /var/jenkins_home/troubleshooting-fill'
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

`df` should show roughly 200M available. Create a second Pipeline job named `artifact-build`, the same way as `baseline`, with this script:

```groovy
podTemplate {
  node(POD_LABEL) {
    stage('Build') {
      sh 'dd if=/dev/zero of=app-bundle.bin bs=1M count=300'
    }
    stage('Archive') {
      archiveArtifacts artifacts: 'app-bundle.bin'
    }
  }
}
```

Select **Build Now**. This time the build **is created** and its console log works: the free space is enough for the log. The **Build** stage succeeds on the agent, which has its own disk. The **Archive** stage fails while copying the file to the controller, and the error appears in the build's console output, not only in the controller log. A partial copy of the artifact can remain in the build's directory and keep using space.

### Scenario 2, without the fill file: builds that never clean up

The same failure happens in real life without anyone filling the volume: every build keeps its artifacts and nothing discards old builds. The [`fill-over-time.Jenkinsfile`](fill-over-time.Jenkinsfile) pipeline reproduces that. Each build creates a file on the agent and archives it on the controller, and the job has no build discarder.

Start from a clean volume (no `troubleshooting-fill`) and check how much space is free:

```sh
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

Create a Pipeline job named `release-build` with the contents of `fill-over-time.Jenkinsfile`, the same way as `baseline`. The default `SIZE_MB` is 1800, which works when between about 3.5 and 5.2 GiB are free: two files fit, three do not. If your free space is outside that range, use roughly the free space divided by 2.5.

Run the job three times, one after another (the first run uses the default; later runs show **Build with Parameters**). Check `df` after each run:

1. Build 1 finishes with **SUCCESS**, and about 1.8 GiB more is used.
2. Build 2 finishes with **SUCCESS**, and the volume is almost full.
3. Build 3 starts, its **Build** stage succeeds on the agent, and the **Archive** stage fails with `No space left on device` in the console output.

After build 3 the volume is at 100%, so the next **Build Now** on any job behaves like scenario 1. `du` shows the space in `jobs/release-build/builds/*/archive`, not in a single obvious file, which is what a real incident looks like. To clean up, delete the three `release-build` runs (or the whole job) and check `df` again.

## Investigate before fixing

```sh
kubectl -n jenkins get pods
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'du -xsh /var/jenkins_home/* 2>/dev/null | sort -h | tail'
kubectl -n jenkins logs jenkins-0 -c jenkins --since=15m | grep -i -E 'no space|IOException'
kubectl -n jenkins get pvc jenkins -o jsonpath='{.status.capacity.storage}{"\n"}'
```

The pod stays `Running` with no restarts: Kubernetes does not treat a full volume as a pod failure. The controller log shows repeated `java.io.IOException: No space left on device`. This log goes to the container's standard output, not to the volume, so it is the one place where Jenkins can still report the error. The AWS setup also ships it to CloudWatch, where it survives a controller restart; see [Container logs in CloudWatch](../../aws/README.md#container-logs-in-cloudwatch). `df` shows the volume is full, and `du` shows what is using it. In this lab the largest entry is `troubleshooting-fill`; in a real incident it is usually `jobs/*/builds` (build history and logs) or archived artifacts. Under **Manage Jenkins → Nodes**, the built-in node may also show a low disk space warning.

## Fix and verify

**Free the space.** This is the immediate fix:

```sh
kubectl -n jenkins exec jenkins-0 -c jenkins -- rm /var/jenkins_home/troubleshooting-fill
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

After scenario 2, also delete the failed `artifact-build` run (open the build, then **Delete build**), which removes any partial artifact it left behind. Check `df` again: usage should be back near the baseline.

Select **Build Now** on the `baseline` job again and confirm that the build finishes with **SUCCESS**.

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

The same cause produced two different symptoms. When the volume was already full, the build never existed: there was no console log to read, and the evidence was only in the **controller log**. When the volume filled during the build, the console showed an error in an archive step, which looks like a build problem. In both cases Kubernetes reported a healthy pod, and `df` and `du` **inside the volume** identified the cause. Expanding the volume fixes the symptom; retention fixes the cause.

## References

- [Kubernetes: expanding persistent volume claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
- [Amazon EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [Jenkins Pipeline: build discarder](https://www.jenkins.io/doc/pipeline/steps/workflow-multibranch/#properties-set-job-properties)

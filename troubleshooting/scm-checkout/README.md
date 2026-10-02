# Agent connects, but project checkout fails

## Incident

The agent pod starts and connects to Jenkins, but the Pipeline fails when fetching project source. In production, a deleted branch, changed repository URL, expired credential, or missing repository permission can produce this class of failure. This exercise uses a nonexistent branch so the failure is reproducible without exposing a credential.

Use the [main setup](../../README.md). Create a separate Jenkins **Pipeline** job with **Pipeline script**. Do not use **Pipeline script from SCM** for this exercise: Jenkins would need to fetch the Jenkinsfile before the diagnostic stages could run. This lab requires the agent image to have Git installed; the chart's current inbound-agent image in this kind cluster does.

## Reproduce

```groovy
podTemplate {
  node(POD_LABEL) {
    stage('Check agent') {
      sh 'hostname; git --version'
    }
    stage('Checkout source') {
      git branch: 'branch-does-not-exist-for-lab',
          url: 'https://github.com/jenkinsci/git-plugin.git'
    }
    stage('Build') {
      sh 'echo Build started'
    }
  }
}
```

Run the job. **Check agent** should succeed, **Checkout source** should fail, and **Build** should not execute. If the first stage fails, investigate the agent image before diagnosing Git.

## Investigate before fixing

Read the Pipeline console output around the `git` step. Confirm the repository URL, the branch Jenkins tried to resolve, and the error text. From an environment with Git and network access, compare the requested branch with the remote branches:

```sh
git ls-remote --heads https://github.com/jenkinsci/git-plugin.git
```

If the output shows other branches but not `branch-does-not-exist-for-lab`, the branch selection is the cause. If the remote cannot be reached at all, check DNS, proxy, TLS, and egress from the environment doing the checkout. If a private repository returns an authentication error, verify the Jenkins `credentialsId` and that its credential type matches the repository protocol. Avoid putting passwords or tokens in repository URLs.

## Fix and verify

Replace the branch with one shown by `git ls-remote`, then run the job again. The checkout and **Build** stages should pass. Keep the agent and cluster configuration unchanged: they already worked in the first stage.

## Presentation point

A failed Jenkins job does not always mean a broken Jenkins agent. The successful first stage separates **infrastructure success** from a **project source configuration** failure.

## References

- [Jenkins Git Pipeline step](https://www.jenkins.io/doc/pipeline/steps/git/)
- [Jenkins credentials](https://www.jenkins.io/doc/book/security/credentials/)

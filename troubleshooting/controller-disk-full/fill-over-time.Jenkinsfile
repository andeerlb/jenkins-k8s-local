// Each build archives a large file on the controller and nothing is ever discarded,
// so JENKINS_HOME grows on every run. With the default size, builds 1 and 2 fit in the
// 5 GiB volume and build 3 fails in the Archive stage with "No space left on device".
properties([
  parameters([
    string(name: 'SIZE_MB', defaultValue: '1800', description: 'Size of the archived file, in MiB')
  ])
])

podTemplate {
  node(POD_LABEL) {
    stage('Build') {
      sh "dd if=/dev/zero of=release-${env.BUILD_NUMBER}.bin bs=1M count=${params.SIZE_MB ?: '1800'}"
      sh 'ls -lh release-*.bin'
    }
    stage('Archive') {
      archiveArtifacts artifacts: 'release-*.bin'
    }
  }
}

// Each branch requests its own agent pod from the Kubernetes plugin.
parallel(
  agent1: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agent 1') {
          sh 'hostname; sleep 30'
        }
      }
    }
  },
  agent2: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agent 2') {
          sh 'hostname; sleep 30'
        }
      }
    }
  },
  agent3: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agent 3') {
          sh 'hostname; sleep 30'
        }
      }
    }
  }
)

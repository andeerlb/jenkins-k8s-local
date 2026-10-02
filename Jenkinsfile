// Cada branch solicita um pod agente independente ao plugin Kubernetes.
parallel(
  agente1: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agente 1') {
          sh 'hostname; sleep 30'
        }
      }
    }
  },
  agente2: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agente 2') {
          sh 'hostname; sleep 30'
        }
      }
    }
  },
  agente3: {
    podTemplate {
      node(POD_LABEL) {
        stage('Agente 3') {
          sh 'hostname; sleep 30'
        }
      }
    }
  }
)

# Jenkins em Kubernetes local

Um cluster [kind](https://kind.sigs.k8s.io/) com dois workers e um Jenkins instalado pelo [chart oficial Helm](https://charts.jenkins.io/). O controller coordena os jobs. O plugin Kubernetes cria um pod agente por execução e o remove quando ela termina. Os workers do Kubernetes são nós do cluster; os agentes do Jenkins são pods que rodam nesses nós.

## Pré-requisitos

- Docker em execução
- `kind`, `kubectl` e `helm` instalados
- Recursos suficientes no computador para o controller e os agentes (comece com pelo menos 4 CPUs e 8 GiB de RAM disponíveis)

## Subir o cluster e instalar o Jenkins

Execute na raiz deste repositório:

```sh
kind create cluster --name jenkins-local --config kind.yaml
kubectl config current-context
kubectl get nodes
kubectl get storageclass

helm repo add jenkins https://charts.jenkins.io
helm repo update
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  --values helm/values.yaml \
  --wait --timeout 10m

kubectl -n jenkins get pods,pvc
helm get notes jenkins -n jenkins
```

O contexto esperado é `kind-jenkins-local`. Confirme antes do comando Helm para não instalar em outro cluster. O chart gera a senha inicial; `helm get notes` mostra como recuperá-la.

## Acessar

Em outro terminal:

```sh
kubectl -n jenkins port-forward svc/jenkins 8080:8080
```

Abra <http://localhost:8080> e entre com o usuário `admin` e a senha indicada pelas notas do Helm.

## Testar três agentes simultâneos

Na interface, crie um job **Pipeline**, selecione **Pipeline script from SCM**, informe a URL deste repositório quando ele tiver um remoto acessível pelo Jenkins e use `Jenkinsfile` como caminho do script. Para testar somente no computador, crie um job **Pipeline**, selecione **Pipeline script** e cole o conteúdo do `Jenkinsfile`.

Durante o build, acompanhe os pods:

```sh
kubectl -n jenkins get pods -w
```

As três branches de `parallel` solicitam três agentes. A quantidade que roda ao mesmo tempo depende da CPU e memória disponíveis. Os pods agentes são temporários; o controller guarda configuração e jobs no PVC.

Para executar jobs Flutter ou Android, substitua o exemplo por uma imagem de agente com Flutter, Java e Android SDK. Builds iOS precisam de um agente macOS fora deste cluster Linux.

## Remover

```sh
helm uninstall jenkins -n jenkins
```

O PVC pode continuar após o `helm uninstall`. `kind delete cluster --name jenkins-local` remove o cluster local e seus dados, inclusive os dados do Jenkins armazenados nele.

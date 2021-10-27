#!/bin/sh

cat << EOF
####################################
### Define Environment Variables ###
####################################
EOF

if [[ ! -z "${CODECOMMIT_BASE_REF}" ]]; then CICD_BRANCH_TO="${CODECOMMIT_BASE_REF/refs\/heads\//}"; fi
if [[ ! -z "${CODEBUILD_WEBHOOK_BASE_REF}" ]]; then CICD_BRANCH_TO="${CODEBUILD_WEBHOOK_BASE_REF/refs\/heads\//}"; fi
if [[ ! -z "${CODECOMMIT_HEAD_REF}" ]]; then CICD_BRANCH_FROM="${CODECOMMIT_HEAD_REF/refs\/heads\//}"; fi
if [[ ! -z "${CODEBUILD_WEBHOOK_HEAD_REF}" ]]; then CICD_BRANCH_FROM="${CODEBUILD_WEBHOOK_HEAD_REF/refs\/heads\//}"; fi

if [[ -z "${CICD_BRANCH_TO}" ]]; then CICD_BRANCH_TO="master"; fi
if [[ -z "${CICD_BRANCH_FROM}" ]]; then CICD_BRANCH_FROM="master"; fi

if [[ "${CICD_BRANCH_TO}" == env/* ]]; then
  CICD_TARGET=${CICD_BRANCH_TO/env\//}
  ACCESS_KEY=AWS_ACCESS_KEY_ID_$(echo ${CICD_TARGET} | tr [a-z] [A-Z])
  if [[ ! -z "${!ACCESS_KEY}" ]]; then
    _TARGET=${CICD_TARGET}
  else
    echo "[WARN] Attempted to switch to '${CICD_TARGET}' environment, but '${ACCESS_KEY}' was missing..."
  fi
fi

if [[ -z "${_CLUSTER}" ]]; then _CLUSTER="eks-use1-msg-kafka-cluster"; fi
if [[ -z "${_NAMESPACE}" ]]; then _NAMESPACE="confluent"; fi
if [[ -z "${_TARGET}" ]]; then _TARGET="sandbox"; fi

_CWD="$( cd "$(dirname "$0")/.." >/dev/null 2>&1 ; pwd -P )"

_TARGETS=("sandbox" "dev" "qc" "bt" "prod")
if [[ ! "${_TARGETS[@]}" =~ "${_TARGET}" ]]; then
  echo >&2 "[ERROR] _TARGET '${_TARGET}' is not supported. aborting..."
  exit 1
fi

_CICD_OPTS=""
if [[ "${CODECOMMIT_EVENT}" == "pullRequestApprovalStateChanged" ]]; then _CICD_OPTS="${_CICD_OPTS}&approved"; fi
if [[ "${CODEBUILD_WEBHOOK_EVENT}" == "PULL_REQUEST_MERGED" ]]; then _CICD_OPTS="${_CICD_OPTS}&merged"; fi

cat << EOF
####################################
### Allocate Dedicated Namespace ###
####################################
EOF

aws --version > /dev/null 2>&1 || { echo >&2 "[ERROR] aws is missing. aborting..."; exit 1; }
aws eks update-kubeconfig --name ${_CLUSTER}

kubectl apply -f ${_CWD}/kubernetes/kube-system/aws-auth-cm-${_TARGET}.yaml
kubectl describe configmap aws-auth -n kube-system

kubectl version > /dev/null 2>&1 || { echo >&2 "[ERROR] kubectl is missing. aborting..."; exit 1; }
kubectl create namespace ${_NAMESPACE}
kubectl config set-context --current --namespace ${_NAMESPACE}

kubectl delete pods ldap-0 --grace-period=0 --force

cat << EOF
#################################
### Enable Confluent Operator ###
#################################
EOF

helm version > /dev/null 2>&1 || { echo >&2 "[ERROR] helm is missing. aborting..."; exit 1; }
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

cat << EOF
#########################################################################
### Upgrade the Confluent Platform custom resource definitions (CRDs) ###
#########################################################################
EOF
helm pull confluentinc/confluent-for-kubernetes --untar
kubectl apply -f confluent-for-kubernetes/crds/

cat << EOF
##################################
### Install Confluent Operator ###
##################################
EOF

helm upgrade -i operator confluentinc/confluent-for-kubernetes --set licenseKey="$(cat ${_CWD}/kubernetes/_creds/license.txt)"
kubectl get pods

cat << EOF
#################################
### Install OpenLdap Service  ###
#################################
EOF

helm upgrade -i ldap ${_CWD}/kubernetes/_ldap -f ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/ldap.yaml
kubectl get pods

cat << EOF
#########################################
### Deploy Confluent Platform Secrets ###
#########################################
EOF

kubectl create secret generic credential \
  --from-file="plain-users.json=${_CWD}/kubernetes/_creds/sasl-kafka-plain-users.json" \
  --from-file="digest-users.json=${_CWD}/kubernetes/_creds/sasl-zookeeper-digest-users.json" \
  --from-file="digest.txt=${_CWD}/kubernetes/_creds/creds-digest-users.txt" \
  --from-file="plain.txt=${_CWD}/kubernetes/_creds/creds-plain-users.txt" \
  --from-file="basic.txt=${_CWD}/kubernetes/_creds/creds-basic-users.txt" \
  --from-file="ldap.txt=${_CWD}/kubernetes/_creds/creds-ldap-users.txt"

# openssl genrsa -out ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/tls.key 2048

# openssl req -new -key ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/tls.key \
#   -out ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/tls.crt \
#   -x509 -days 365 -subj "/C=US/ST=CA/L=NewYork/O=TCH/OU=RTPBI/CN=PrivateCA"

kubectl create secret tls ca-pair-sslcerts \
  --cert="${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/tls.crt" \
  --key="${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/tls.key"

# openssl genrsa -out ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.key 2048

# openssl rsa -in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.key \
#   -outform PEM -pubout -out ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.pub

# ### REPLACE SECRET ###
# kubectl create secret generic mds-token \
#   --from-file="mdsPublicKey.pem=${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.pub" \
#   --from-file="mdsTokenKeyPair.pem=${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.key"
#   --save-config --dry-run=client -o yaml | kubectl replace -f -

kubectl create secret generic mds-token \
  --from-file="mdsPublicKey.pem=${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.pub" \
  --from-file="mdsTokenKeyPair.pem=${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/mds.key"

kubectl create secret generic mds-client \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client.txt"

kubectl create secret generic c3-mds-client \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client-c3.txt"

kubectl create secret generic connect-mds-client \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client-connect.txt"

kubectl create secret generic sr-mds-client \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client-sr.txt"

kubectl create secret generic ksqldb-mds-client \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client-ksqldb.txt"

kubectl create secret generic rest-credential \
  --from-file="bearer.txt=${_CWD}/kubernetes/_creds/mds-client.txt" \
  --from-file="basic.txt=${_CWD}/kubernetes/_creds/mds-client.txt"

kubectl_apply() {
  if [[ -z "${1}" ]]; then
    echo >&2 "[ERROR] argument 1 (path) is missing. aborting..."
    exit 1
  fi

  for file in ${1}; do
    _CICD_DIFF=$(kubectl diff -f ${file})
    if [[ ! -z "${_CICD_DIFF}" ]]; then
      echo "${_CICD_DIFF}"
      if [[ "${_CICD_OPTS}" == *approved* ]]; then
        kubectl apply -f ${file}
      else
        kubectl apply -f ${file} --dry-run=server -v=8
      fi
      unset _CICD_DIFF
    fi
  done
}

kubectl_exec() {
  if [[ -z "${1}" ]]; then
    echo >&2 "[ERROR] argument 1 (path) is missing. aborting..."
    exit 1
  fi

  if [[ -z "${2}" ]]; then
    echo >&2 "[ERROR] argument 2 (exec cmd) is missing. aborting..."
    exit 1
  fi

  for file in ${1}; do
    # _CICD_DIFF=$(git diff ${file})
    # if [[ ! -z "${_CICD_DIFF}" ]]; then
    #   echo "${_CICD_DIFF}"
    #   kubectl exec ${2} < ${file}
    # fi

    kubectl exec ${2} "$(cat ${file})"
  done
}

cat << EOF
############################################
### Deploy Confluent Platform Components ###
############################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/platform/*.yaml"
kubectl get pods

cat << EOF
#############################################
### Deploy Confluent Platform Rolebinding ###
#############################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/rolebinding/*.yaml"
kubectl get pods

cat << EOF
#######################################
### Deploy Confluent Platform Topic ###
#######################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/topic/*.yaml"
kubectl get pods

cat << EOF
########################################
### Deploy Confluent Platform KSQLDB ###
########################################
EOF

kubectl_exec "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/ksqldb/*.sql" "ksqldb-0 -- ksql --execute"
kubectl get pods

# cat << EOF
# ##################################
# ### Explore Confluent Platform ###
# ##################################
# EOF

# kubectl get confluent
# kubectl describe kafka
# kubectl port-forward svc/controlcenter 9021:9021
# kubectl logs -lapp.kubernetes.io/name=ksqldb-client -f

# cat << EOF
# ####################################
# ### Tear Down Confluent Platform ###
# ####################################
# EOF

# kubectl delete -f ${_CWD}/docs/examples/platform-confluent-default.yaml
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/topic/*.yaml; do kubectl delete -f ${file}; done
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/rolebinding/*.yaml; do kubectl delete -f ${file}; done
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/platform/*.yaml; do kubectl delete -f ${file}; done
# helm delete ldap
# helm delete operator
# kubectl delete namespace ${_NAMESPACE}
# ### kubectl get namespace ${_NAMESPACE} -o json > ${_NAMESPACE}.json
# ### ### edit ${_NAMESPACE}.json and remove "kubernetes" from `finalize` object
# ### kubectl replace --raw "/api/v1/namespaces/${_NAMESPACE}/finalize" -f ./${_NAMESPACE}.json

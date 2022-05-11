#!/bin/sh

aws --version > /dev/null 2>&1 || { echo >&2 "[ERROR] aws is missing. aborting..."; exit 1; }
helm version > /dev/null 2>&1 || { echo >&2 "[ERROR] helm is missing. aborting..."; exit 1; }
kubectl version --client > /dev/null 2>&1 || { echo >&2 "[ERROR] kubectl is missing. aborting..."; exit 1; }

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
if [[ -z "${_SERVICEACCOUNT}" ]]; then _SERVICEACCOUNT="confluent-sa"; fi
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

aws eks update-kubeconfig --name ${_CLUSTER}

kubectl create namespace ${_NAMESPACE}
kubectl config set-context --current --namespace ${_NAMESPACE}

kubectl create serviceaccount ${_SERVICEACCOUNT}
kubectl get serviceaccount
kubectl describe serviceaccount ${_SERVICEACCOUNT}

cat << EOF
#################################
### Configure HashiCorp Vault ###
#################################
EOF

kubectl create namespace hashicorp
kubectl config set-context --current --namespace hashicorp

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault --set='server.dev.enabled=true' hashicorp/vault --namespace hashicorp

kubectl exec vault-0 -- /bin/sh -c 'rm -rf /tmp/*'
kubectl cp ${_CWD}/kubernetes/hashicorp/policy_vault.hcl vault-0:/tmp
kubectl cp ${_CWD}/kubernetes/creds vault-0:/tmp
kubectl cp ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs vault-0:/tmp

#kubectl exec vault-0 -- /bin/sh -c "vault auth disable kubernetes"
kubectl exec vault-0 -- /bin/sh -c "vault auth enable kubernetes"

kubectl exec vault-0 -- /bin/sh -c 'vault write auth/kubernetes/config \
  issuer=https://kubernetes.default.svc.cluster.local \
  token_reviewer_jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
  kubernetes_host=https://$KUBERNETES_PORT_443_TCP_ADDR:443 \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_iss_validation=true'

kubectl exec vault-0 -- /bin/sh -c "vault write sys/policy/app policy=@/tmp/policy_vault.hcl"
kubectl exec vault-0 -- /bin/sh -c "vault write auth/kubernetes/role/confluent-operator ttl=24h \
  bound_service_account_names=${_SERVICEACCOUNT} bound_service_account_namespaces=${_NAMESPACE} policies=app"

kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/license.txt | base64 | vault kv put /secret/license.txt license=-"

kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/controlcenter/basic-server.txt | base64 | vault kv put /secret/controlcenter/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/connect/basic-client.txt | base64 | vault kv put /secret/connect-client/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/schemaregistry/basic-server.txt | base64 | vault kv put /secret/schemaregistry/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/schemaregistry/basic-client.txt | base64 | vault kv put /secret/schemaregistry-client/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/ksqldb/basic-server.txt | base64 | vault kv put /secret/ksqldb/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/ksqldb/basic-client.txt | base64 | vault kv put /secret/ksqldb-client/basic.txt basic=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/zookeeper-server/digest-jaas.conf | base64 | vault kv put /secret/zookeeper/digest-jaas.conf digest=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/kafka-client/plain-jaas.conf | base64 | vault kv put /secret/kafka-client/plain-jaas.conf plainjaas=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/kafka-server/plain-jaas.conf | base64 | vault kv put /secret/kafka-server/plain-jaas.conf plainjaas=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/kafka-server/apikeys.json | base64 | vault kv put /secret/kafka-server/apikeys.json apikeys=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/kafka-server/digest-jaas.conf | base64 | vault kv put /secret/kafka-server/digest-jaas.conf digestjaas=-"

kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/ldap.txt | base64 | vault kv put /secret/ldap.txt ldapsimple=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/mds-client-connect.txt | base64 | vault kv put /secret/connect/bearer.txt bearer=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/mds-client-controlcenter.txt | base64 | vault kv put /secret/controlcenter/bearer.txt bearer=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/mds-client-kafka-rest.txt | base64 | vault kv put /secret/kafka/bearer.txt bearer=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/mds-client-ksql.txt | base64 | vault kv put /secret/ksqldb/bearer.txt bearer=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/creds/rbac/mds-client-schemaregistry.txt | base64 | vault kv put /secret/schemaregistry/bearer.txt bearer=-"

kubectl exec vault-0 -- /bin/sh -c "cat /tmp/certs/mds.pub | base64 | vault kv put /secret/mdsPublicKey.pem mdspublickey=-"
kubectl exec vault-0 -- /bin/sh -c "cat /tmp/certs/mds.key | base64 | vault kv put /secret/mdsTokenKeyPair.pem mdstokenkeypair=-"

kubectl get pod

cat << EOF
################################
### Configure AWS Private CA ###
################################
EOF

kubectl create namespace cert-manager
kubectl config set-context --current --namespace cert-manager
# wget https://github.com/jetstack/cert-manager/releases/download/v1.7.1/cert-manager.yaml && mv cert-manager.yaml ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/
kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/cert-manager.yaml"

kubectl create namespace aws-pca-issuer
kubectl config set-context --current --namespace aws-pca-issuer

helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm repo update
helm install awspca/aws-privateca-issuer --generate-name --namespace aws-pca-issuer

_CERTIFICATE_AUTHORITY_ARN="$(aws acm-pca list-certificate-authorities --query 'CertificateAuthorities[0].Arn')"
_CERTIFICATE_AUTHORITY_ARN=${_CERTIFICATE_AUTHORITY_ARN//\"/}
if [[ "${_CERTIFICATE_AUTHORITY_ARN}" == "null" ]]; then
  aws acm-pca create-certificate-authority \
    --certificate-authority-configuration file://${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/ca_auth_config.json \
    --revocation-configuration file://${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/ca_revoke_config.json \
    --certificate-authority-type "ROOT" --idempotency-token 01234567 --tags Key=Name,Value=ExamplePrivateCA
fi

_CERTIFICATE_AUTHORITY_STATUS="$(aws acm-pca list-certificate-authorities --query 'CertificateAuthorities[0].Status')"
_CERTIFICATE_AUTHORITY_STATUS=${_CERTIFICATE_AUTHORITY_STATUS//\"/}
if [[ "${_CERTIFICATE_AUTHORITY_STATUS}" != "ACTIVE" ]]; then

  if [[ "${_CERTIFICATE_AUTHORITY_ARN}" == "null" ]]; then
    _CERTIFICATE_AUTHORITY_ARN="$(aws acm-pca list-certificate-authorities --query 'CertificateAuthorities[0].Arn')"
    _CERTIFICATE_AUTHORITY_ARN=${_CERTIFICATE_AUTHORITY_ARN//\"/}
  fi

  aws acm-pca get-certificate-authority-csr \
    --certificate-authority-arn ${_CERTIFICATE_AUTHORITY_ARN} \
    --output text --endpoint https://acm-pca.amazonaws.com --region us-east-1 > ca.csr

  aws acm-pca issue-certificate \
    --certificate-authority-arn ${_CERTIFICATE_AUTHORITY_ARN} \
    --csr file://ca.csr --signing-algorithm SHA256WITHRSA --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 --validity Value=180,Type=DAYS

  aws acm-pca get-certificate-authority-certificate \
    --certificate-authority-arn ${_CERTIFICATE_AUTHORITY_ARN} \
    --region us-east-1 --output text > cacert.pem
fi

aws acm-pca list-certificate-authorities

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/eks-cluster-issuer.yaml"
kubectl get awspcaclusterissuer

cat << EOF
####################################
### Allocate Dedicated Namespace ###
####################################
EOF

kubectl_apply "${_CWD}/kubernetes/kube-system/aws-auth-cm-${_TARGET}.yaml"
kubectl describe configmap aws-auth -n kube-system

kubectl create namespace ${_NAMESPACE}
kubectl config set-context --current --namespace ${_NAMESPACE}

cat << EOF
############################################
### Configure AWS Private CA Certificate ###
############################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/awspca/certificate.yaml"
kubectl get certificate

cat << EOF
#####################################
### Configure Custom StorageClass ###
#####################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/platform/0-storage.yaml"
kubectl get storageclass

cat << EOF
#################################
### Enable Confluent Operator ###
#################################
EOF

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

_LICENSE=$(cat ${_CWD}/kubernetes/creds/license.txt)
helm upgrade -i operator confluentinc/confluent-for-kubernetes --set licenseKey="${_LICENSE/license\=/}" --set debug="true"
kubectl get pod

cat << EOF
#################################
### Install OpenLdap Service  ###
#################################
EOF

helm upgrade -i ldap ${_CWD}/kubernetes/_ldap -f ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/certs/ldap.yaml
kubectl get pod
# kubectl exec -it ldap-0 -- /bin/sh
# ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=rtpbi,dc=com' -D "cn=mds,dc=rtpbi,dc=com" -w 'Developer!'

cat << EOF
#########################################
### Deploy Confluent Platform Secrets ###
#########################################
EOF

kubectl create secret generic rest-credential \
  --from-file="bearer.txt=${_CWD}/kubernetes/creds/rbac/kafkarestclass/bearer.txt" \
  --from-file="basic.txt=${_CWD}/kubernetes/creds/rbac/kafkarestclass/bearer.txt"
kubectl get secret
# kubectl get secret rest-credential -o=go-template='{{index .data "bearer.txt"}}' | base64 -d

cat << EOF
#############################################
### Deploy Confluent Platform Rolebinding ###
#############################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/rolebinding/*.yaml"
kubectl get confluentrolebinding

cat << EOF
############################################
### Deploy Confluent Platform Components ###
############################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/platform/*.yaml"
kubectl get pod

cat << EOF
#######################################
### Deploy Confluent Platform Topic ###
#######################################
EOF

kubectl_apply "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/topic/*.yaml"
kubectl get pod

cat << EOF
########################################
### Deploy Confluent Platform KSQLDB ###
########################################
EOF

kubectl_exec "${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/ksqldb/*.sql" "ksqldb-0 -- ksql --execute"
kubectl get pod

# cat << EOF
# #############################################
# ### Create Kafka Stream w/ Existing Topic ###
# #############################################
# EOF

# curl --http1.1 -X "POST" https://ksqldb.rtpbi.com/ksql -H "Accept: application/vnd.ksql.v1+json" -u ksql:lPf5C6JjJN7BW7HjJhOn#  -d $'{"ksql": "SHOW STREAMS;" }'
# curl --http1.1 -X "POST" https://ksqldb.rtpbi.com/ksql -H "Accept: application/vnd.ksql.v1+json" -u ksql:lPf5C6JjJN7BW7HjJhOn#  -d $'{"ksql": "CREATE OR REPLACE STREAM SRC_JSON (TX_DTIME STRING, MSG_TYPE STRING, TOTAL_INTBK_SETT_AMOUNT DECIMAL(10, 2), ACTION_CODE STRING, INSTRUCTED_PID STRING, INSTRUCTED_PNAME STRING, INSTRUCTING_PNAME STRING, DUPFLAG STRING, E2EREF STRING, PAY_TYPE_CAT_PURP STRING, PAY_TYPE_LCL_INSTRM STRING, SETTCYCLE STRING, INSTRUCTING_PID STRING, TX_STATUS STRING, TX_ID STRING KEY) WITH (KAFKA_TOPIC=\'test-end-to-end\', KEY_FORMAT=\'KAFKA\', PARTITIONS=\'3\', REPLICAS=\'2\', VALUE_FORMAT=\'JSON\',timestamp=\'TX_DTIME\', timestamp_format=\'yyyy-MM-dd\'\'T\'\'HH:mm:ss.SSS\');" }'
# aws elbv2 modify-listener --alpn-policy HTTP2Preferred --listener-arn arn:aws:elasticloadbalancing:us-east-1:097777094708:listener/net/aec872debcc2c42faafe5d38502d414e/83f3eeaf251bd0bb/7bd5aec2ae45a3a4

# cat << EOF
# ##################################
# ### Explore Confluent Platform ###
# ##################################
# EOF

# kubectl get confluent
# kubectl describe kafka
# kubectl port-forward svc/controlcenter 9021:9021
# kubectl logs -lapp.kubernetes.io/name=ksqldb-client -f --tail=100

# cat << EOF
# ####################################
# ### Tear Down Confluent Platform ###
# ####################################
# EOF

# kubectl delete -f ${_CWD}/docs/examples/platform-confluent-default.yaml
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/topic/*.yaml; do kubectl delete -f ${file}; done
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/platform/*.yaml; do kubectl delete -f ${file}; done
# for file in ${_CWD}/kubernetes/${_NAMESPACE}/${_TARGET}/rolebinding/*.yaml; do kubectl delete -f ${file}; done
# helm delete ldap
# helm delete operator
# kubectl delete namespace ${_NAMESPACE}
# ### kubectl get namespace ${_NAMESPACE} -o json > ${_NAMESPACE}.json
# ### ### edit ${_NAMESPACE}.json and remove "kubernetes" from `finalize` object
# ### kubectl replace --raw "/api/v1/namespaces/${_NAMESPACE}/finalize" -f ./${_NAMESPACE}.json

#!/bin/bash
set -e

# Set the cluster and user names
CLUSTER_NAME="${1:-$CLUSTER_NAME}"
DOMAIN="${2:-$DOMAIN}"
CLUSTER_FQDN="${CLUSTER_NAME}.${DOMAIN}"
USER_NAME="system:admin"
CA_NAME="admin-kubeconfig-signer"
LOADBALANCER_SIGNER_NAME="loadbalancer-serving-signer"
LOCALHOST_SIGNER_NAME="localhost-serving-signer"
SERVICE_NETWORK_SIGNER_NAME="service-network-serving-signer"
INGRESS_OPERATOR_SIGNER_NAME="ingresskey-ingress-operator"

# Set the paths for certificates and kubeconfig file
CERT_DIR="./ibi-certs"
CONFIG_CERT_DIR="./ibi-config/certs"
KUBECONFIG_FILE=kubeconfig.ibi

# Create a temporary OpenSSL configuration file
config_file=$(mktemp)

function cleanup {
    rm -fr "$config_file"
}
trap cleanup EXIT

cat <<EOF > "$config_file"
[req]
distinguished_name = req

[v3_req]
basicConstraints = CA:TRUE
keyUsage = keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
EOF

# Create the certificate directory
mkdir -p "${CERT_DIR}"
mkdir -p "${CONFIG_CERT_DIR}"

# Generate a private key for the CA
openssl genpkey -algorithm RSA -out "${CERT_DIR}/${CA_NAME}-key.pem"

# Create a CSR for the CA
openssl req -new -key "${CERT_DIR}/${CA_NAME}-key.pem" -out "${CERT_DIR}/${CA_NAME}-csr.pem" -subj "/CN=${CA_NAME}"

# Self-sign the CSR to generate the CA certificate
openssl x509 -req -in "${CERT_DIR}/${CA_NAME}-csr.pem" -signkey "${CERT_DIR}/${CA_NAME}-key.pem" -out "${CERT_DIR}/${CA_NAME}.crt"

# Generate a private key for the user
openssl genpkey -algorithm RSA -out "${CERT_DIR}/${USER_NAME}-key.pem"

# Generate a CSR for the user
openssl req -new -key "${CERT_DIR}/${USER_NAME}-key.pem" -out "${CERT_DIR}/${USER_NAME}-csr.pem" -subj "/CN=${USER_NAME}"

# Sign the user's CSR with the CA
openssl x509 -req -in "${CERT_DIR}/${USER_NAME}-csr.pem" -CA "${CERT_DIR}/${CA_NAME}.crt" -CAkey "${CERT_DIR}/${CA_NAME}-key.pem" -CAcreateserial -out "${CERT_DIR}/${USER_NAME}-crt.pem" -days 365

# Function to generate keys and self-signed certificates
generate_self_signed_certs() {
    local SIGNER_NAME="$1"
    local COMMON_NAME="$2"
    # Generate a private key
    openssl genpkey -algorithm RSA -out "${CERT_DIR}/${SIGNER_NAME}-key.pem"

    # Create a CSR for the CA
    openssl req -new -key "${CERT_DIR}/${SIGNER_NAME}-key.pem" -out "${CERT_DIR}/${SIGNER_NAME}-csr.pem" -subj "/OU=openshift/CN=${COMMON_NAME}" -config <(echo -e "[req]\ndistinguished_name=req\nstring_mask=pkix\n")

    # Self-sign the CSR to generate the CA certificate
    openssl x509 -req -in "${CERT_DIR}/${SIGNER_NAME}-csr.pem" -signkey "${CERT_DIR}/${SIGNER_NAME}-key.pem" -out "${CERT_DIR}/${SIGNER_NAME}.crt" -days 365 -extensions v3_req  -extfile "$config_file"

}

# Generate serving-signer certificates
generate_self_signed_certs "${LOADBALANCER_SIGNER_NAME}" kube-apiserver-lb-signer
generate_self_signed_certs "${LOCALHOST_SIGNER_NAME}" kube-apiserver-localhost-signer
generate_self_signed_certs "${SERVICE_NETWORK_SIGNER_NAME}" kube-apiserver-service-network-signer
generate_self_signed_certs "${INGRESS_OPERATOR_SIGNER_NAME}" "ingress-operator@$(date +%s)"


# Concatenate serving-signer certificates into a single file
cat "${CERT_DIR}/${LOADBALANCER_SIGNER_NAME}.crt" "${CERT_DIR}/${LOCALHOST_SIGNER_NAME}.crt" "${CERT_DIR}/${SERVICE_NETWORK_SIGNER_NAME}.crt" "${CERT_DIR}/${INGRESS_OPERATOR_SIGNER_NAME}.crt" > "${CERT_DIR}/serving-signer-ca.crt"

# Set the cluster context in kubeconfig
kubectl config set-cluster "${CLUSTER_NAME}" --server="https://api.${CLUSTER_FQDN}:6443" --certificate-authority="${CERT_DIR}/serving-signer-ca.crt" --embed-certs=true --kubeconfig="${KUBECONFIG_FILE}"

# Set the user in kubeconfig
kubectl config set-credentials "${USER_NAME}" --client-certificate="${CERT_DIR}/${USER_NAME}-crt.pem" --client-key="${CERT_DIR}/${USER_NAME}-key.pem" --embed-certs=true --kubeconfig="${KUBECONFIG_FILE}"

# Set the context in kubeconfig
kubectl config set-context "${CLUSTER_NAME}" --cluster="${CLUSTER_NAME}" --user="${USER_NAME}" --kubeconfig="${KUBECONFIG_FILE}"

# Use the context in kubeconfig
kubectl config use-context "${CLUSTER_NAME}" --kubeconfig="${KUBECONFIG_FILE}"

echo "Kubeconfig file and certificates generated successfully."

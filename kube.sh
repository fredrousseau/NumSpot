#!/bin/bash
# v.1.1 - Add condition command sed (line 72-78)

set -e  # Stop script execution on error

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: The 'jq' utility is not installed! Please install it and try again." >&2
    exit 1
fi

export REGION="cloudgouv-eu-west-1"
export SERVICE_ACCOUNT_KEY=""
export SERVICE_ACCOUNT_SECRET=""
export SPACE_ID=""
export CLUSTER_ID=""

#### No changes are required below that line

# Function to check if a variable is set
check_variable() {
    local var_name="$1"
    local var_value="${!var_name}"
    if [[ -z "$var_value" ]]; then
        echo "❌ ERROR: The variable $var_name is empty!" >&2
        exit 1
    fi
}

# Check required variables
check_variable "REGION"
check_variable "SERVICE_ACCOUNT_KEY"
check_variable "SERVICE_ACCOUNT_SECRET"
check_variable "SPACE_ID"
check_variable "CLUSTER_ID"

export ENDPOINT="https://api.$REGION.numspot.com"

echo "🔄 Retrieving authentication token..."
RESPONSE=$(curl --silent --fail --location "$ENDPOINT/iam/token" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Authorization: Basic $(echo -n $SERVICE_ACCOUNT_KEY:$SERVICE_ACCOUNT_SECRET | base64)" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=openid+offline") || { echo "❌ ERROR: Failed to retrieve token!"; exit 1; }

TOKEN=$(echo "$RESPONSE" | jq -r .access_token)
check_variable "TOKEN"

echo "✅ Token successfully retrieved!"

echo "🔄 Fetching cluster information..."
CLUSTER_INFO=$(curl --silent --fail --location "$ENDPOINT/kubernetes/spaces/$SPACE_ID/clusters/$CLUSTER_ID" \
    --header "Authorization: Bearer $TOKEN") || { echo "❌ ERROR: Failed to retrieve cluster information!"; exit 1; }

BASTION_IP=$(jq -r '.clientBastionPublicIP' <<< "$CLUSTER_INFO")
API_URL=$(jq -r '.apiUrl' <<< "$CLUSTER_INFO")

check_variable "BASTION_IP"
check_variable "API_URL"

echo "✅ Cluster information retrieved:"
echo "🔹 Bastion IP : $BASTION_IP"
echo "🔹 API URL : $API_URL"

echo "🔄 Downloading kubeconfig..."
curl --silent --fail --location "$ENDPOINT/kubernetes/spaces/$SPACE_ID/clusters/$CLUSTER_ID/kubeconfig" \
    --output kubeconfig.yaml \
    --header "Authorization: Bearer $TOKEN" || { echo "❌ ERROR: Failed to download kubeconfig!"; exit 1; }

echo "🔄 Patching kubeconfig..."
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS (BSD sed)
  sed -i '' "s|$API_URL|127.0.0.1|g" kubeconfig.yaml || { echo "❌ ERROR: Failed to patch kubeconfig!"; exit 1; }
else
  # Linux (GNU sed)
  sed -i "s|$API_URL|127.0.0.1|g" kubeconfig.yaml || { echo "❌ ERROR: Failed to patch kubeconfig!"; exit 1; }
fi

echo "✅ Kubeconfig downloaded and patched!"

echo "🔄 Downloading private key..."
curl --silent --fail --location "$ENDPOINT/kubernetes/spaces/$SPACE_ID/clusters/$CLUSTER_ID/privatekey" \
    --output privatekey.rsa \
    --header "Authorization: Bearer $TOKEN" || { echo "❌ ERROR: Failed to download private key!"; exit 1; }

chmod 0600 privatekey.rsa || { echo "❌ ERROR: Failed to set permissions for private key!"; exit 1; }

echo "✅ Private key downloaded successfully!"

# Add bastion host to known_hosts to prevent SSH warning
echo "🔄 Adding Bastion Host to known_hosts..."
ssh-keyscan "$BASTION_IP" >> ~/.ssh/known_hosts 2>/dev/null || { echo "❌ ERROR: Failed to add Bastion Host to known_hosts!"; exit 1; }
echo "✅ Bastion Host added to known_hosts"

# Start SSH tunnel in background
echo "🔄 Establishing SSH tunnel to bastion host..."
if [[ -f "privatekey.rsa" && -n "$BASTION_IP" && -n "$API_URL" ]]; then
    ssh -i privatekey.rsa -o IdentitiesOnly=yes -l client-tunnel -L 127.0.0.1:6443:$API_URL:6443 -N $BASTION_IP &
    echo "✅ SSH tunnel established in background (port 6443 → $API_URL:6443)"
else
    echo "❌ ERROR: Cannot establish SSH tunnel - Missing private key, Bastion IP, or API URL!" >&2
    exit 1
fi

unset REGION
unset SERVICE_ACCOUNT_KEY
unset SERVICE_ACCOUNT_SECRET
unset SPACE_ID
unset CLUSTER_ID



#!/bin/bash

REGION=$1
EKSCLUSTERNAME=$2

export RancherURL="ranchereksqs.kaap.com"
export HostedZone="kaap.com"

#Install tools
sudo yum -y install jq

aws eks update-kubeconfig --name ${EKSCLUSTERNAME} --region $REGION

#Install kubectl
curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.19.0/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
kubectl version --client

kubectl get svc

# Install helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Start by creating the mandatory resources for NGINX Ingress in your cluster:
# Parameterize version 0.40.2
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.40.2/deploy/static/provider/aws/deploy.yaml

#Download latest Rancher repository
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm fetch rancher-stable/rancher

# Create NameSpace:
kubectl create namespace cattle-system

# The Rancher management server is designed to be secure by default and requires SSL/TLS configuration.
# Defining the Ingress resource (with SSL termination) to route traffic to the services created above
# Example ${RancherURL} is like ranchereksqs.awscloudbuilder.com
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=${RancherURL}/O=${RancherURL}"

#Create the secret in the cluster:
kubectl create secret tls tls-secret --key tls.key --cert tls.crt

# Delete validatingwebhookconfiguration
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=ranchereksqs.kaap.com  \
  --set ingress.tls.source=secret

#Create Route53 Hosted Zone
export CALLER_REF=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')
MYMAC=`curl http://169.254.169.254/latest/meta-data/mac`
VPCID=`curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MYMAC/vpc-id`
aws route53 create-hosted-zone --name ${HostedZone} --caller-reference $CALLER_REF --hosted-zone-config Comment="Rancher Domain,PrivateZone=True" --vpc VPCRegion=$REGION,VPCId=$VPCID

#Extract Hosted Zone ID:
export ZONE_ID=$(aws route53 list-hosted-zones-by-name |  jq --arg name "${HostedZone}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id' | cut -d"/" -f3)

#Create Resource Record Set
export NLB=`kubectl get svc -n ingress-nginx -o json | jq -r ".items[0].status.loadBalancer.ingress[0].hostname"`
export NLB_NAME=`echo $NLB | cut -d"-" -f1`

#Create Resource Record Set
export NLB_HOSTEDZONE=$(aws elbv2 describe-load-balancers --region $REGION --names $NLB_NAME | jq -r ".LoadBalancers[0].CanonicalHostedZoneId")

cat > rancher-record-set.json <<EOF
{
        "Comment": "CREATE/DELETE/UPSERT a record ",
        "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                        "Name": "${RancherURL}.",
            "SetIdentifier": "RancherEKS",
            "Region": "$REGION",
                        "Type": "A",
                        "AliasTarget": {
                                "HostedZoneId": "$NLB_HOSTEDZONE",
                                "DNSName": "dualstack.$NLB",
                                "EvaluateTargetHealth": false
                        }
                }
        }]
}
EOF

aws route53 change-resource-record-sets --region $REGION --hosted-zone-id $ZONE_ID --change-batch file://rancher-record-set.json
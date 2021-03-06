#!/bin/bash

set -eux

APT_MIRROR=$1
INSECURE_REGISTRY=$2
INSECURE_REGISTRY_PORT=$3

[ -z "$APT_MIRROR" ] && echo "Usage: deploy-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1
[ -z "$INSECURE_REGISTRY" ] && echo "Usage: deploy-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1
[ -z "$INSECURE_REGISTRY_PORT" ] && echo "Usage: deploy-squid.sh VPC_ID APT_MIRROR INSECURE_REGISTRY INSECURE_REGISTRY PORT." && exit 1

VPC_CIDR=172.32.0.0/16
PRIVATE_SUBNET_CIDR=172.32.0.0/24
PUBLIC_SUBNET_CIDR=172.32.1.0/24

alias aws="aws --output text"

function clean {
  NAME=cleanup-$VPC_ID.sh
  if [ ! -f $NAME ]; then
    touch $NAME
    chmod +x $NAME
  fi
  echo -e "$1\n$(cat $NAME)" > $NAME
}

# Create A Virtual Private cloud and collect its ID.
VPC_ID=$(aws ec2 create-vpc --cidr $VPC_CIDR | awk '{print $7}')
clean "aws ec2 delete-vpc --vpc-id $VPC_ID"

# Enable DNS and hostnames on the VPC. TODO: see if this is necessary.
aws ec2 modify-vpc-attribute --vpc-id=$VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id=$VPC_ID --enable-dns-hostnames

# Create a private subnet and collect its ID.
PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIVATE_SUBNET_CIDR | awk '{print $9}')
clean "aws ec2 delete-subnet --subnet-id $PRIVATE_SUBNET_ID"

# Create a public subnet and collect its ID.
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_SUBNET_CIDR | awk '{print $9}')
clean "aws ec2 delete-subnet --subnet-id $PUBLIC_SUBNET_ID"

# When launching a node on the private subnet, give it a public IP automatically. TODO: wat? do we really need/want to do this?
aws ec2 modify-subnet-attribute --subnet-id $PRIVATE_SUBNET_ID --map-public-ip-on-launch

# When launching a node on the public subnet, give it a public IP automatically. TODO: wat? do we really need/want to do this?
aws ec2 modify-subnet-attribute --subnet-id $PUBLIC_SUBNET_ID --map-public-ip-on-launch

# Create an internet gateway and collect its ID.
GATEWAY_ID=$(aws ec2 create-internet-gateway | cut -f 2)
clean "aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAY_ID"

# Attach the gateway to our VPC.
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway $GATEWAY_ID
clean "aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAY_ID --vpc-id $VPC_ID"

# Get the id of the default route table.
DEFAULT_ROUTE_TABLE_ID=$(aws --output text ec2 describe-route-tables | grep $VPC_ID | cut -f 2)

# Create a route that says "If you're going, like, anywhere, go through our gateway."
aws ec2 create-route --route-table-id $DEFAULT_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GATEWAY_ID

# Get the default security group attached to our VPC.
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID | awk '{print $6}')

# Allow ingress for ssh everywhere.
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Allow ingress on all ports for the private subnet. TODO; make this more confined later?
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol all --port 0-65535 --cidr $PRIVATE_SUBNET_CIDR

if [ ! -f cdk-offline.pem ]; then
    aws ec2 create-key-pair --key-name cdk-offline > cdk-offline.pem
fi

# Create the squid instance.
SQUID_INSTANCE_ID=$(aws ec2 run-instances --output json --count 1 --image-id ami-bb1901d8 --instance-type t2.micro --key-name cdk-offline --subnet-id $PUBLIC_SUBNET_ID | jq -r '.Instances[].InstanceId')
clean "until aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].State.Name' | grep terminated; do sleep 1; echo 'wating for instance termination'; done"
clean "aws ec2 terminate-instances --instance-ids $SQUID_INSTANCE_ID"

# Wait for it to come up.
until aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].State.Name' | grep running; do sleep 1; echo 'waiting for squid instance'; done
aws ec2 modify-instance-attribute --instance-id $SQUID_INSTANCE_ID --source-dest-check '{"Value": false}'

# Get the squid instance's IP address.
SQUID_INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].PublicIpAddress')

# Create a route table.
SQUID_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --output json| jq -r '.RouteTable.RouteTableId')

# Create a route that routes everything through the squid instance.
aws ec2 create-route --route-table-id $SQUID_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --instance-id $SQUID_INSTANCE_ID
clean "aws ec2 delete-route-table --route-table-id $SQUID_ROUTE_TABLE_ID"

# Associate the route with the private subnet.
SQUID_ROUTE_TABLE_ASSOCIATION_ID=$(aws ec2 associate-route-table --route-table-id $SQUID_ROUTE_TABLE_ID --subnet-id $PRIVATE_SUBNET_ID)

# Wait for the squid instance to respond to ssh
until ssh -i cdk-offline.pem ubuntu@$SQUID_INSTANCE_IP echo waiting; do sleep 1; done

# Install squid on the squid instance
scp -i cdk-offline.pem ./deploy-squid.sh ubuntu@$SQUID_INSTANCE_IP:.
ssh -i cdk-offline.pem ubuntu@$SQUID_INSTANCE_IP ./deploy-squid.sh $VPC_ID $APT_MIRROR $INSECURE_REGISTRY $INSECURE_REGISTRY_PORT

scp -i cdk-offline.pem cdk-offline.pem ubuntu@$SQUID_INSTANCE_IP:.

set +x
echo VPC_ID                             $VPC_ID
echo VPC_CIDR                           $VPC_CIDR
echo PRIVATE_SUBNET_CIDR                $PRIVATE_SUBNET_CIDR
echo PUBLIC_SUBNET_CIDR                 $PUBLIC_SUBNET_CIDR
echo PRIVATE_SUBNET_ID                  $PRIVATE_SUBNET_ID
echo PUBLIC_SUBNET_ID                   $PUBLIC_SUBNET_ID
echo GATEWAY_ID                         $GATEWAY_ID
echo DEFAULT_ROUTE_TABLE_ID             $DEFAULT_ROUTE_TABLE_ID
echo SECURITY_GROUP_ID                  $SECURITY_GROUP_ID
echo SQUID_INSTANCE_ID                  $SQUID_INSTANCE_ID
echo SQUID_INSTANCE_IP                  $SQUID_INSTANCE_IP
echo SQUID_ROUTE_TABLE_ID               $SQUID_ROUTE_TABLE_ID
echo SQUID_ROUTE_TABLE_ASSOCIATION_ID   $SQUID_ROUTE_TABLE_ASSOCIATION_ID

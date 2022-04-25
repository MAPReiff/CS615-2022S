#!/bin/sh

# I pledge my honor that I have abided by the Stevens Honor System.

# Credits:
#   The following functions were based on Jan Schaumann's AWS aliases - https://stevens.netmeister.org/615/awsaliases
#   start_instance, instance_name, ec2_wait

# Call in values from config file
if [ -e "./config" ]
then
    . ./config
    echo "Config file loaded..."
else
    echo "Config file not found, please follow the instructions in the README"
    exit 1
fi

# Functions
start_ubuntu () {
    subnet_data=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$subnet")
    subnet_id=$(echo $subnet_data | jq -r '.Subnets[].SubnetId')
    
    security_group_data=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=$securityGroup")
    security_group_id=$(echo $security_group_data | jq -r '.SecurityGroups[].GroupId')
    
    start_instance() {
        aws ec2 run-instances --key-name $keyName --image-id $@   \
        --instance-type t2.micro    \
        --subnet-id "${subnet_id}"    \
        --security-group-ids "${security_group_id}" |   \
        jq -r '.Instances[].InstanceId'
    }
    
    
    echo "Starting an AWS EC2 instance, please wait..."
    instance=$(start_instance ami-0f593aebffc0070e1)
    echo "Waiting for instance to become available..."
    instance_info=$(ec2_wait $instance)
    
    instance_address=$(instance_name $instance)
    
    volume_id=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values=EC2-Backup-MR" --query "Volumes[*].VolumeId" --output text)
    
    # We now have the instance ID, instance address, and volume ID
    dummy=$(aws ec2 attach-volume --volume-id $volume_id --instance-id $instance --device /dev/sdf)
    
    # Sometimes this seems to not attach instantly causing issues
    sleep 10
    
}

kill_instance () {
    dummy=$(aws ec2 detach-volume --volume-id $volume_id --instance-id $instance)
    dummy=$(aws ec2 terminate-instances --instance-ids $instance)
}

instance_name () {
    aws ec2 describe-instances --instance-ids $@ | jq -r ".Reservations[].Instances[].PublicDnsName"
}

# Function to wait for the instance to become available
ec2_wait () {
    aws ec2 wait instance-running --instance-ids $@
    sleep 60
    instance_name $@
}

if [ -e "./.ec2backup_MR" ]
then
    start_ubuntu
    
    echo "If promted, please agree to authenticate with the instance by typing 'yes' and then pressing enter"
    
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mkdir /backup")
    sleep 5
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mount /dev/xvdf /backup")
    sleep 5
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo chown -R ubuntu:ubuntu /backup")
    sleep 5
    
    echo "You can now access your instance at by typing 'ssh -i /home/$USER/.ssh/$keyName.pem ubuntu@$instance_address'"
    echo "If you wish to terminate the instance, please type 'aws ec2 detach-volume --volume-id $volume_id --instance-id $instance' and then 'aws ec2 terminate-instances --instance-ids $instance'"
    
else
    echo "No backup found, goodbye..."
    exit 1
fi
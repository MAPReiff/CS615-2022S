#!/bin/sh

# I pledge my honor that I have abided by the Stevens Honor System.

if [ -e "./config" ]
then
    . ./config # Not needed but part of the check
    echo "Config file loaded..."
else
    echo "Config file not found, please follow the instructions in the README"
    exit 1
fi

if [ -e "./.ec2backup_MR" ]
then
    echo "About to nuke the EBS volume, you have 15 seconds to kill the script with Ctrl+C before any action is taken"
    sleep 15
    
    echo "Nuking volume..."
    volume_id=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values=EC2-Backup-MR" --query "Volumes[*].VolumeId" --output text)
    
    dummy=$(aws ec2 delete-volume --volume-id $volume_id)
    
    rm ./.ec2backup_MR
    rm ./config
    
    echo "Done"
    
else
    echo "No backup found, goodbye..."
    exit 1
fi
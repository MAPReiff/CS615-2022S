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

# Function to start an Ubuntu instance
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

# Function to make the backup tar of the local directory on the remote instance
make_backup () {
    backup_name=$(date +"%Y-%m-%d_%H-%M-%S")
    dummy=$(tar zcvf - $dir | ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "cat > /backup/$backup_name.tar.gz")
    sleep 5
    echo "Successfully backed up $dir, which is located at /backup/$backup_name.tar.gz on future instances"
}

# Function to kill the instance as to not incur costs
kill_instance () {
    dummy=$(aws ec2 detach-volume --volume-id $volume_id --instance-id $instance)
    dummy=$(aws ec2 terminate-instances --instance-ids $instance)
}

# Function to get the size of local directory as well as it's size in gigabytes
local_dir_size () {
    echo "Attempting to determine local directory size, please wait..."
    dir_size=$(du -sh $dir | awk '{print $1}')
    dir_size_raw=$(du -sh $dir | awk '{print $1}' | tr -dc '0-9')
    local_dir_bytes=$(du -sb $dir | awk '{print $1}')
}

# Function to get the size of the remote directory as well as check if there is enough space left for a new backup
dir_size_check () {
    echo "Attempting to determine remote directory size, please wait..."
    # Initial connection
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "exit")
    free_bytes_remote=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "df -B1 /backup | tail -1 | awk '{print \$4}'")
    local_dir_bytes=$(du -sb $dir | awk '{print $1}')
    dir_diff=$(expr $free_bytes_remote - $local_dir_bytes)
    
    # Check if there is enough space with a 100 byte buffer (just in case)
    if [ "$dir_diff" -lt 100 ]; then
        echo "Error: There is not enough space on the remote server to backup."
        echo "If you would like to continue, please delete some previous backups on the remote server."
        kill_instance
        exit 1
    else
        echo "There is enough space on the remote server to backup."
    fi
    
    
}

# Function to get the name of the instance
instance_name () {
    aws ec2 describe-instances --instance-ids $@ | jq -r ".Reservations[].Instances[].PublicDnsName"
}

# Function to wait for the instance to become available
ec2_wait () {
    aws ec2 wait instance-running --instance-ids $@
    sleep 60
    instance_name $@
}



# Check if first run
if [ -e "./.ec2backup_MR" ]
then
    # The user has already run this script before
    echo "Welcome back!"
    start_ubuntu
    
    echo "If promted, please agree to authenticate with the instance by typing 'yes' and then pressing enter"
    
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mkdir /backup")
    sleep 5
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mount /dev/xvdf /backup")
    sleep 5
    dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo chown -R ubuntu:ubuntu /backup")
    sleep 5
    
    dir=$backupDir
    local_dir_size
    dir_size_check
    
    # If we get to here => there is enough space to backup
    make_backup
    
    echo "Your new backup has been created."
    
    kill_instance
    
    exit 1
    
    
else
    # The user has not run this script before
    echo "Welcome to the AWS EC2 backup script! It appears this is the first time you have run this script, so you must answer some configuration questions."
    
    dir=$backupDir
    local_dir_size
    
    echo "Your selected directory is currently $local_dir_bytes bytes in size. In order to backup this directory, you need to have at least $local_dir_bytes bytes available on your EBS volume."
    echo "I recomend creating a volume that is atleast 5 times the size of your directory. The minimum volume size is 1GB"
    echo "Please enter the size of the volume you would like to create as a whole number in bytes: "
    read vol_size
    
    # Check if selected volume size is a valid number
    if expr "$vol_size" : '[0-9][0-9]*$'>/dev/null; then
        # Check if selected volume size is greater than directory size
        if [ $vol_size -ge $local_dir_bytes ]
        then
            # User input is large enough
            vol_size_gb=$(expr $vol_size / 1000000000)
            if [ $vol_size_gb -lt 1 ]
            then
                vol_size_gb=1
            fi
            
            
            # Make EBS volume
            echo "Creating volume of size $vol_size_gb GB"
            zone=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$subnet" | jq -r '.Subnets[].AvailabilityZone')
            dummy=$(aws ec2 create-volume --size $vol_size_gb --availability-zone $zone --volume-type gp2 --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=EC2-Backup-MR}]')
            echo "Volume created, waiting for volume to become available..."
            dummy=$(aws ec2 wait volume-available --volume-ids $(aws ec2 describe-volumes --filters "Name=tag:Name,Values=EC2-Backup-MR" --query "Volumes[*].VolumeId" --output text))
            
            # Start an instance and mount the volume
            start_ubuntu
            
            echo "If promted, please agree to authenticate with the instance by typing 'yes' and then pressing enter"
            
            # Format the volume
            dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mkfs -t ext4 /dev/xvdf")
            sleep 5
            dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mkdir /backup")
            sleep 5
            dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo mount /dev/xvdf /backup")
            sleep 5
            dummy=$(ssh -o "StrictHostKeyChecking no" -i "/home/$USER/.ssh/$keyName.pem" ubuntu@$instance_address "sudo chown -R ubuntu:ubuntu /backup")
            sleep 5
            
            # Create the initial backup
            make_backup
            
            echo $dir > ./.ec2backup_MR
            echo "Your initial backup has been created."
            
            kill_instance
            
            exit 1
            
        else
            echo "The selected volume size is too small to backup $dir. Please try again."
            exit 1
        fi
    else
        echo "The selected volume size is not a whole number, please try again."
        exit 1
    fi
    
    
fi
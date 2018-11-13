#!/bin/bash
# TODO: create additional resources including vnet,nsg
# TODO: reuse NSG: js-directorNSG

OWNER_TAG=${OWNER_TAG:=${USER}}  # example: jsmith
SSH_USERNAME=${SSH_USERNAME:=${USER}} # example: gregj/centos/ec2-user
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:=${USER}-rg} # example: jsmith-rg
AZ_INSTANCE_NAME=${AZ_INSTANCE_NAME:=abc-director} # example: js-director
SSH_KEYNAME=${SSH_KEYNAME:=abc-azure.pub}

echo """Using the following values:
Owner tag: ${OWNER_TAG}
SSH User: ${SSH_USERNAME}
Azure resource group: ${AZ_RESOURCE_GROUP} (must exist on your Azure axcount)
Instance name: ${AZ_INSTANCE_NAME}
SSH public key: ~/.ssh/${SSH_KEYNAME}
"""
read -p  "Proceed? [Y/n]: " -n 1 -r
# echo

if [[ ! $REPLY =~ ^[Yy]$ ]] ; then
    echo Set the environment variables you require, then run this script again - exiting
    exit 1
fi

echo 'Starting provisioning of instance on Azure - please use default DNS for your VNET!'
az account set --subscription 'Sales Engineering'

if [ "$?" != 0 ] ; then
   exit
fi

# 1) Launch combined Director/MariaDB instance
dirinfo=$(az vm create \
    --size STANDARD_DS13_V2 \
    --resource-group ${AZ_RESOURCE_GROUP} \
    --name ${AZ_INSTANCE_NAME} \
    --tags owner=${OWNER_TAG} \
    --image CentOS \
    --admin-username ${SSH_USERNAME} \
    --ssh-key-value  "`cat ~/.ssh/${SSH_KEYNAME}`")

if [ "$?" != 0 ] ; then
    echo "Error encountered:"
    echo ${dirinfo}
    exit 1
fi
    # --image js-centos74-director26 \

if [ -x $(dirname "$0")/create-ssh-config.sh ] ; then
    $(dirname "$0")/create-ssh-config.sh
fi
p
dirip=`echo ${dirinfo} | jq -r '.publicIpAddress'`
echo 'Fixing up the .ssh/config file'
gsed -i.bak "/^ *Host azure-director */,/^ *Host /{s/^\( *Hostname *\)\(.*\)/\1$dirip/}" ~/.ssh/config
diff ~/.ssh/config.bak ~/.ssh/config

echo 'Disabling selinux'
ssh -tt ${SSH_USERNAME}@azure-director "sudo sed -i.bak 's/^\(SELINUX=\).*/\1disabled/' /etc/selinux/config"


echo 'Assuring instance can resolve internet DHCP - in case DNS is still set to custom'
ssh -tt ${SSH_USERNAME}@azure-director "echo 'nameserver 8.8.8.8' | sudo tee -a /etc/resolve.conf"

echo 'Setting up MariaDB/MySQL, Altus Director and Bind'

dirhost=`ssh ${SSH_USERNAME}@azure-director "hostname -f"`
dirshorthost=`ssh ${SSH_USERNAME}@azure-director "hostname -s"`
ssh -tt ${SSH_USERNAME}@azure-director 'sudo yum -y install wget git'
ssh ${SSH_USERNAME}@azure-director "wget 'https://raw.githubusercontent.com/gregoryg/macathon-director/master/bin/configure-director-instance.sh'"
ssh -tt ${SSH_USERNAME}@azure-director 'bash ./configure-director-instance.sh'

echo 'Placing director-scripts on instance - use DNS scripts on Azure'
ssh ${SSH_USERNAME}@azure-director "git clone 'https://github.com/cloudera/director-scripts.git'"

echo 'Now please set DNS - internal domain will be set to cdh-cluster.internal'
ssh -tt ${SSH_USERNAME}@azure-director 'sudo bash ./director-scripts/azure-dns-scripts/bind-dns-setup.sh'

echo Starting proxy
emacsclient -n '/ssh:${SSH_USERNAME}@azure-director:'
echo waiting for Director to become available
sleep 30
for i in 1 2 3 4 5 6 7 8 9 10
do
    ssh ${SSH_USERNAME}@azure-director 'nc `hostname` 7189 < /dev/null'
    ret=$?
    if [ ${ret} == 0 ] ; then
        # echo Opening Director web page
        # open "http://${dirhost}:7189/"
        break
    else
        echo -n .
        sleep 10
    fi
done

echo
echo "Cloudera Director URL is http://${dirshorthost}.cdh-cluster.internal:7189/"

# NOTE: Selinux must be disabled or set to permissive to allow DNS to be registered for cluster instances
echo 'rebooting to fix selinux'
ssh -tt ${SSH_USERNAME}@azure-director 'sudo reboot'

exit 0
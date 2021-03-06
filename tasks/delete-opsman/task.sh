#!/bin/bash

export ROOT_DIR=`pwd`
source $ROOT_DIR/nsx-ci-pipeline/functions/copy_binaries.sh

export GOVC_INSECURE=1
export GOVC_URL=$GOVC_URL
export GOVC_USERNAME=$GOVC_USERNAME
export GOVC_PASSWORD=$GOVC_PASSWORD

# Delete Active OpsMan
resource_pool_path=$(govc find . -name ${GOVC_RESOURCE_POOL} | grep -i resource )
echo "Found resource_pool_path : $resource_pool_path"

possible_opsmans=$(govc find $resource_pool_path -type m -guest.ipAddress ${OPS_MGR_HOST} -runtime.powerState poweredOn)
# REMOVE ME - temporarily to clean up ops mgr
if [ "$possible_opsmans" == "" ]; then
  possible_opsmans=$(govc find $resource_pool_path -type m -name ${OM_VM_NAME} )
fi
echo "Found possible_opsmans : $possible_opsmans"

for opsman in ${possible_opsmans}; do
  network="$(govc vm.info -r=true -json ${opsman} | jq -r '.VirtualMachines[0].Guest.Net[0].Network')"
  if [[ ${network} == ${GOVC_NETWORK} ]]; then
    echo "Powering off and removing ${opsman}..."
    set +e
    govc vm.power -vm.ipath=${opsman} -off
    set -e    
  fi
  govc vm.destroy -vm.ipath=${opsman}
  STATUS=$?
  echo "Done destroying Opsman: ${opsman}"
done

exit $STATUS

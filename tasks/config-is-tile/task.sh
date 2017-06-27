#!/bin/bash -e

chmod +x om-cli/om-linux
CMD=./om-cli/om-linux

export ROOT_DIR=`pwd`
export SCRIPT_DIR=$(dirname $0)
export NSX_GEN_OUTPUT_DIR=${ROOT_DIR}/nsx-gen-output
export NSX_GEN_OUTPUT=${NSX_GEN_OUTPUT_DIR}/nsx-gen-out.log
export NSX_GEN_UTIL=${NSX_GEN_OUTPUT_DIR}/nsx_parse_util.sh

if [ -e "${NSX_GEN_OUTPUT}" ]; then
  source ${NSX_GEN_UTIL} ${NSX_GEN_OUTPUT}
  # Read back associate array of jobs to lbr details
  # created by hte NSX_GEN_UTIL script
  source /tmp/jobs_lbr_map.out
  IS_NSX_ENABLED=$(./om-cli/om-linux -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k \
             curl -p "/api/v0/deployed/director/manifest" 2>/dev/null | jq '.cloud_provider.properties.vcenter.nsx' || true )

else
  echo "Unable to retreive nsx gen output generated from previous nsx-gen-list task!!"
  exit 1
fi

# Check if Bosh Director is v1.11 or higher
export bosh_product_version=$(./om-cli/om-linux -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k \
           curl -p "/api/v0/staged/products" 2>/dev/null | jq '.[].product_version' | tr -d '"')
export bosh_major_version=$(echo $bosh_product_version | awk -F '.' '{print $1}' )
export bosh_minor_version=$(echo $bosh_product_version | awk -F '.' '{print $2}' )


export cf_product_version=$(./om-cli/om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
          curl -p "/api/v0/staged/products" -x GET | jq '.[] | select(.installation_name | contains("cf-")) | .product_version' | tr -d '"')

export cf_major_version=$(echo $cf_product_version | awk -F '.' '{print $1}' )
export cf_minor_version=$(echo $cf_product_version | awk -F '.' '{print $2}' )


# Can only support one version of the default isolation segment tile
# Search for the tile using the specified product name if available
# or search using p-iso as default iso product name
if [[ -z "$PRODUCT_NAME" ]]; then
  TILE_RELEASE=`./om-cli/om-linux -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k available-products | grep p-iso`
else
  TILE_RELEASE=`./om-cli/om-linux -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k available-products | grep $PRODUCT_NAME`
fi

export PRODUCT_NAME=`echo $TILE_RELEASE | cut -d"|" -f2 | tr -d " "`
export PRODUCT_VERSION=`echo $TILE_RELEASE | cut -d"|" -f3 | tr -d " "`

./om-cli/om-linux -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k stage-product -p $PRODUCT_NAME -v $PRODUCT_VERSION

export PRODUCT_MAJOR_VERSION=$(echo $PRODUCT_VERSION | awk -F '.' '{print $1}' )
export PRODUCT_MINOR_VERSION=$(echo $PRODUCT_VERSION | awk -F '.' '{print $2}' )


function fn_get_azs {
     local azs_csv=$1
     echo $azs_csv | awk -F "," -v braceopen='{' -v braceclose='}' -v name='"name":' -v quote='"' -v OFS='"},{"name":"' '$1=$1 {print braceopen name quote $0 quote braceclose}'
}

TILE_AVAILABILITY_ZONES=$(fn_get_azs $TILE_AZS_ISO)


NETWORK=$(cat <<-EOF
{
  "singleton_availability_zone": {
    "name": "$TILE_AZ_ISO_SINGLETON"
  },
  "other_availability_zones": [
    $TILE_AVAILABILITY_ZONES
  ],
  "network": {
    "name": "$NETWORK_NAME"
  }
}
EOF
)

if [[ -z "$SSL_CERT" ]]; then
DOMAINS=$(cat <<-EOF
  {"domains": ["*.$SYSTEM_DOMAIN", "*.$APPS_DOMAIN", "*.login.$SYSTEM_DOMAIN", "*.uaa.$SYSTEM_DOMAIN"] }
EOF
)

  CERTIFICATES=`$CMD -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k curl -p "$OPS_MGR_GENERATE_SSL_ENDPOINT" -x POST -d "$DOMAINS"`

  export SSL_CERT=`echo $CERTIFICATES | jq '.certificate' | tr -d '"'`
  export SSL_PRIVATE_KEY=`echo $CERTIFICATES | jq '.key' | tr -d '"'`

  echo "Using self signed certificates generated using Ops Manager..."

fi

# Supporting atmost 3 isolation segments
case "$NETWORK_NAME" in
  *01) 
  export ROUTER_STATIC_IPS=$ISOZONE_SWITCH_1_GOROUTER_STATIC_IPS
  export TCP_ROUTER_STATIC_IPS=$ISOZONE_SWITCH_1_TCPROUTER_STATIC_IPS
  ;;
  *02)
  export ROUTER_STATIC_IPS=$ISOZONE_SWITCH_2_GOROUTER_STATIC_IPS
  export TCP_ROUTER_STATIC_IPS=$ISOZONE_SWITCH_2_TCPROUTER_STATIC_IPS
  ;;
  *03)
  export ROUTER_STATIC_IPS=$ISOZONE_SWITCH_3_GOROUTER_STATIC_IPS
  export TCP_ROUTER_STATIC_IPS=$ISOZONE_SWITCH_3_TCPROUTER_STATIC_IPS
  ;;
esac


PROPERTIES=$(cat <<-EOF
{
  ".isolated_diego_cell.executor_disk_capacity": {
    "value": "$CELL_DISK_CAPACITY"
  },
  ".isolated_diego_cell.executor_memory_capacity": {
    "value": "$CELL_MEMORY_CAPACITY"
  },
  ".isolated_diego_cell.garden_network_mtu": {
    "value": $APPLICATION_NETWORK_MTU
  },
  ".isolated_diego_cell.insecure_docker_registry_list": {
    "value": "$INSECURE_DOCKER_REGISTRY_LIST"
  },
  ".isolated_diego_cell.placement_tag": {
    "value": "$SEGMENT_NAME"
  },
EOF
)

# Add the static ips to list above if nsx not enabled in Bosh director 
# If nsx enabled, a security group would be dynamically created with vms 
# and associated with the pool by Bosh
if [ "$IS_NSX_ENABLED" == "null" -o "$IS_NSX_ENABLED" == "" ]; then
  PROPERTIES=$(cat <<-EOF
$PROPERTIES
  ".isolated_router.static_ips": {
    "value": "$ROUTER_STATIC_IPS"
  },
EOF
)
fi


# No C2C support in PCF 1.9, 1.10 and older versions
export SUPPORTS_C2C=false
if [ "$PRODUCT_MAJOR_VERSION" -le 1 ]; then
  if [ "$PRODUCT_MINOR_VERSION" -ge 11 ]; then
    export SUPPORTS_C2C=true   
  fi
else
  export SUPPORTS_C2C=true
fi

# PCF supports C2C
if [ "$SUPPORTS_C2C" == "true" ]; then

  # If user wants C2C enabled, then add additional properties
  if [ "$TILE_ISO_ENABLE_C2C" == "enable" ]; then
    PROPERTIES=$(cat <<-EOF
$PROPERTIES
  ".properties.container_networking.enable.network_cidr": {
      "value": "$TILE_ISO_C2C_NETWORK_CIDR"
  },
  ".properties.container_networking.enable.vtep_port": {
    "value": "$TILE_ISO_C2C_VTEP_PORT"
  }
}
EOF
)
  else
    # User does not want c2c
    PROPERTIES=$(cat <<-EOF
$PROPERTIES
  ".properties.container_networking.disable.garden_network_pool": {
    "value": "$APPLICATION_NETWORK_CIDR"
  }
}
EOF
)
  fi
  # End of SUPPORTS_C2C
else  
  # Older version, no C2C support
  PROPERTIES=$(cat <<-EOF
$PROPERTIES
  ".isolated_diego_cell.garden_network_pool": {
      "value": "$APPLICATION_NETWORK_CIDR"
    }
}
EOF
)
fi
# End of PROPERTIES block


RESOURCES=$(cat <<-EOF
{
  "isolated_router": {
    "instance_type": {"id": "automatic"},
    "instances" : $IS_ROUTER_INSTANCES
  },
  "isolated_diego_cell": {
    "instance_type": {"id": "automatic"},
    "instances" : $IS_DIEGO_CELL_INSTANCES
  }
}
EOF
)

$CMD -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k configure-product -n $PRODUCT_NAME -p "$PROPERTIES" -pn "$NETWORK" -pr "$RESOURCES"

if [[ "$SSL_TERMINATION_POINT" == "terminate_at_router" ]]; then
echo "Terminating SSL at the goRouters and using self signed/provided certs..."
SSL_PROPERTIES=$(cat <<-EOF
{
  ".properties.networking_point_of_entry": {
    "value": "$SSL_TERMINATION_POINT"
  },
  ".properties.networking_point_of_entry.terminate_at_router.ssl_rsa_certificate": {
    "value": {
      "cert_pem": "$SSL_CERT",
      "private_key_pem": "$SSL_PRIVATE_KEY"
    }
  },
  ".properties.networking_point_of_entry.terminate_at_router.ssl_ciphers": {
    "value": "$ROUTER_SSL_CIPHERS"
  }
}
EOF
)

elif [[ "$SSL_TERMINATION_POINT" == "terminate_at_router_ert_cert" ]]; then
echo "Terminating SSL at the goRouters and reusing self signed/provided certs from ERT tile..."
SSL_PROPERTIES=$(cat <<-EOF
{
  ".properties.networking_point_of_entry": {
    "value": "$SSL_TERMINATION_POINT"
  }
}
EOF
)

elif [[ "$SSL_TERMINATION_POINT" == "terminate_before_router" ]]; then
echo "Unencrypted traffic to goRouters as SSL terminated at load balancer..."
SSL_PROPERTIES=$(cat <<-EOF
{
  ".properties.networking_point_of_entry": {
    "value": "$SSL_TERMINATION_POINT"
  }
}
EOF
)

fi

$CMD -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k configure-product -n $PRODUCT_NAME -p "$SSL_PROPERTIES"

# if nsx is not enabled, skip remaining steps
if [ "$IS_NSX_ENABLED" == "null" -o "$IS_NSX_ENABLED" == "" ]; then
  exit
fi

# Proceed if NSX is enabled on Bosh Director
# Support NSX LBR Integration

PRODUCT_GUID=$(./om-cli/om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
                     curl -p "/api/v0/staged/products" -x GET \
                     | jq '.[] | select(.installation_name | contains("p-isolation-segment-")) | .guid' | tr -d '"')

# $ISO_TILE_JOBS_REQUIRING_LBR comes filled by nsx-edge-gen list command
# Sample: ERT_TILE_JOBS_REQUIRING_LBR='mysql_proxy,tcp_router,router,diego_brain'
JOBS_REQUIRING_LBR=$ISO_TILE_JOBS_REQUIRING_LBR

# Change to pattern for grep
JOBS_REQUIRING_LBR_PATTERN=$(echo $JOBS_REQUIRING_LBR | sed -e 's/,/\\|/g')

# Get job guids for deployment (from staged product)
./om-cli/om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
                              curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs" 2>/dev/null \
                              | jq '.[] | .[] ' > /tmp/jobs_list.log

for job_guid in $(cat /tmp/jobs_list.log | jq '.guid' | tr -d '"')
do
  job_name=$(cat /tmp/jobs_list.log | grep -B1 $job_guid | grep name | awk -F '"' '{print $4}')
  match=$(echo $job_name | grep -e $JOBS_REQUIRING_LBR_PATTERN  || true)
  if [ "$match" != "" ]; then
    echo "$job requires Loadbalancer..."
    job_name_upper=$(echo ${job_name^^} | sed -e 's/-/_/')
        
    # Check for security group defined for the given job from Env
    # Expecting only one security group env variable per job (can have a comma separated list)
    SECURITY_GROUP=$(env | grep "TILE_ISO_${job_name_upper}_SECURITY_GROUP" | awk -F '=' '{print $2}')

    # Use an auto-security group based on product guid by Bosh 
    # for grouping all vms with the same security group
    NEW_SECURITY_GROUP=\"${PRODUCT_GUID}\"
     # Check if there are multiple security groups
    # If so, wrap them with quotes
    for secgrp in $(echo $SECURITY_GROUP |sed -e 's/,/ /g' )
    do
      NEW_SECURITY_GROUP=$(echo $NEW_SECURITY_GROUP, \"$secgrp\",)
    done
    SECURITY_GROUP=$(echo $NEW_SECURITY_GROUP | sed -e 's/,$//')

    # The associative array comes from sourcing the /tmp/jobs_lbr_map.out file
    # filled earlier by nsx-edge-gen list command
    # Sample associative array content:
    # ERT_TILE_JOBS_LBR_MAP=( ["mysql_proxy"]="$ERT_MYSQL_LBR_DETAILS" ["tcp_router"]="$ERT_TCPROUTER_LBR_DETAILS" 
    # .. ["diego_brain"]="$SSH_LBR_DETAILS"  ["router"]="$ERT_GOROUTER_LBR_DETAILS" )
    # SSH_LBR_DETAILS=[diego_brain]="esg-sabha6:VIP-diego-brain-tcp-21:diego-brain21-Pool:2222"

    # We support atmost 3 iso segments...
    case "$NETWORK_NAME" in
      *01) 
      LBR_DETAILS=${ISO_TILE_1_JOBS_LBR_MAP[$job_name]}
      ;;
      *02)
      LBR_DETAILS=${ISO_TILE_2_JOBS_LBR_MAP[$job_name]}
      ;;
      *03)
      LBR_DETAILS=${ISO_TILE_3_JOBS_LBR_MAP[$job_name]}
      ;;
    esac

    RESOURCE_CONFIG=$(./om-cli/om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
                      curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs/${job_guid}/resource_config" \
                      2>/dev/null)
    #echo "Resource config : $RESOURCE_CONFIG"
    # Remove trailing brace to add additional elements
    # Remove also any empty nsx_security_groups
    RESOURCE_CONFIG=$(echo $RESOURCE_CONFIG | sed -e 's/}$//1' | sed -e 's/"nsx_security_groups": null,//')
    NSX_LBR_PAYLOAD=" \"nsx_lbs\": ["

    index=1
    for variable in $(echo $LBR_DETAILS)
    do
      edge_name=$(echo $variable | awk -F ':' '{print $1}')
      lbr_name=$(echo $variable  | awk -F ':' '{print $2}')
      pool_name=$(echo $variable | awk -F ':' '{print $3}')
      port=$(echo $variable | awk -F ':' '{print $4}')
      monitor_port=$(echo $variable | awk -F ':' '{print $5}')
      echo "ESG: $edge_name, LBR: $lbr_name, Pool: $pool_name, Port: $port, Monitor port: $monitor_port"
      
      # Create a security group with Product Guid and job name for lbr security grp
      job_security_grp=${PRODUCT_GUID}-${job_name}

      #ENTRY="{ \"edge_name\": \"$edge_name\", \"pool_name\": \"$pool_name\", \"port\": \"$port\", \"security_group\": \"$job_security_grp\" }"
      ENTRY="{ \"edge_name\": \"$edge_name\", \"pool_name\": \"$pool_name\", \"port\": \"$port\", \"monitor_port\": \"$monitor_port\", \"security_group\": \"$job_security_grp\" }"
      #echo "Created lbr entry for job: $job_guid with value: $ENTRY"

      if [ "$index" == "1" ]; then          
        NSX_LBR_PAYLOAD=$(echo "$NSX_LBR_PAYLOAD $ENTRY ")
      else
        NSX_LBR_PAYLOAD=$(echo "$NSX_LBR_PAYLOAD, $ENTRY ")
      fi
      index=$(expr $index + 1)
    done

    NSX_LBR_PAYLOAD=$(echo "$NSX_LBR_PAYLOAD ] ")
    #echo "Job: $job_name with GUID: $job_guid and NSX_LBR_PAYLOAD : $NSX_LBR_PAYLOAD"

    UPDATED_RESOURCE_CONFIG=$(echo "$RESOURCE_CONFIG , \"nsx_security_groups\": [ $SECURITY_GROUP ], $NSX_LBR_PAYLOAD }")
    echo "Job: $job_name with GUID: $job_guid and RESOURCE_CONFIG : $UPDATED_RESOURCE_CONFIG"

    # Register job with NSX Pool in Ops Mgr (gets passed to Bosh)
    ./om-cli/om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD  \
            curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs/${job_guid}/resource_config"  \
            -x PUT  -d "${UPDATED_RESOURCE_CONFIG}"

  fi
done

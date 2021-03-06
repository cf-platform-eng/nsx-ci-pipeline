#!/bin/bash

set -eu

export ROOT_DIR=`pwd`
source $ROOT_DIR/nsx-ci-pipeline/functions/copy_binaries.sh
source $ROOT_DIR/nsx-ci-pipeline/functions/check_versions.sh
source $ROOT_DIR/nsx-ci-pipeline/functions/check_null_variables.sh

export SCRIPT_DIR=$(dirname $0)
export NSX_GEN_OUTPUT_DIR=${ROOT_DIR}/nsx-gen-output
export NSX_GEN_OUTPUT=${NSX_GEN_OUTPUT_DIR}/nsx-gen-out.log
export NSX_GEN_UTIL=${NSX_GEN_OUTPUT_DIR}/nsx_parse_util.sh

if [ -e "${NSX_GEN_OUTPUT}" ]; then
  source ${NSX_GEN_UTIL} ${NSX_GEN_OUTPUT}
  # Read back associate array of jobs to lbr details
  # created by hte NSX_GEN_UTIL script
  source /tmp/jobs_lbr_map.out
  IS_NSX_ENABLED=$(om -t https://$OPS_MGR_HOST -u $OPS_MGR_USR -p $OPS_MGR_PWD -k \
               curl -p "/api/v0/deployed/director/manifest" 2>/dev/null | jq '.cloud_provider.properties.vcenter.nsx' || true )

  # if nsx is enabled
  if [ "$IS_NSX_ENABLED" != "null" -a "$IS_NSX_ENABLED" != "" ]; then
    IS_NSX_ENABLED=true
  fi

else
  echo "Unable to retreive nsx gen output generated from previous nsx-gen-list task!!"
  exit 1
fi

# Check if Bosh Director is v1.11 or higher
check_bosh_version
check_available_product_version "p-rabbitmq"

export IS_ERRAND_WHEN_CHANGED_ENABLED=false
if [ $BOSH_MAJOR_VERSION -le 1 ]; then
  if [ $BOSH_MINOR_VERSION -ge 10 ]; then
    export IS_ERRAND_WHEN_CHANGED_ENABLED=true
  fi
else
  export IS_ERRAND_WHEN_CHANGED_ENABLED=true
fi

om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k stage-product \
    -p $PRODUCT_NAME \
    -v $PRODUCT_VERSION

check_staged_product_guid "p-rabbitmq"


function fn_get_azs {
     local azs_csv=$1
     echo $azs_csv | awk -F "," -v braceopen='{' -v braceclose='}' -v name='"name":' -v quote='"' -v OFS='"},{"name":"' '$1=$1 {print braceopen name quote $0 quote braceclose}'
}

prod_network=$(
  jq -n \
    --arg network_name "$NETWORK_NAME" \
    --arg other_azs "$TILE_AZS_RABBIT" \
    --arg singleton_az "$TILE_AZ_RABBIT_SINGLETON" \
    --arg service_network_name "$SERVICE_NETWORK_NAME" \
    '
    {
      "network": {
        "name": $network_name
      },
      "service_network": {
        "name": $service_network_name
      },
      "other_availability_zones": ($other_azs | split(",") | map({name: .})),
      "singleton_availability_zone": {
        "name": $singleton_az
      }
    }
    '
)

has_older_odb_dedicated_plan=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.on_demand_broker_dedicated" | wc -l || true)
has_odb_plan_1=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.on_demand_broker_plan_1" | wc -l || true)

has_odb_plan_vm_type=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.*rabbitmq_vm_type" | wc -l || true)
has_odb_plan_disk_type=$(echo $STAGED_PRODUCT_PROPERTIES | jq . |grep ".properties.*rabbitmq_persistent_disk_type" | wc -l || true)


# Add the static ips to list above if nsx not enabled in Bosh director
# If nsx enabled, a security group would be dynamically created with vms
# and associated with the pool by Bosh

prod_properties=$(
  jq -n \
    --arg tile_rabbit_admin_user $TILE_RABBIT_ADMIN_USER \
    --arg tile_rabbit_admin_passwd $TILE_RABBIT_ADMIN_PASSWD \
    --arg tile_rabbit_proxy_vip "$RABBITMQ_TILE_LBR_IP" \
    --arg tile_rabbit_proxy_ips "$RABBITMQ_TILE_STATIC_IPS" \
    --argjson tile_rabbit_on_demand_plan_1_instance_quota $TILE_RABBIT_ON_DEMAND_PLAN_1_INSTANCE_QUOTA\
    --arg tile_az_rabbit_singleton $TILE_AZ_RABBIT_SINGLETON \
    --arg has_odb_plan_vm_type "$has_odb_plan_vm_type" \
    --arg has_odb_plan_disk_type "$has_odb_plan_disk_type" \
    --arg has_older_odb_plan_vm_type "$has_odb_plan_vm_type" \
    --arg has_older_odb_plan_disk_type "$has_odb_plan_disk_type" \
    --arg has_older_odb_dedicated_plan "$has_older_odb_dedicated_plan" \
    --arg has_odb_plan_1 "$has_odb_plan_1" \
    --arg tile_rabbit_odb_plan_1_vm_type "$TILE_RABBIT_ON_DEMAND_PLAN_1_VM_TYPE" \
    --arg tile_rabbit_odb_plan_1_persistent_disk_type "$TILE_RABBIT_ON_DEMAND_PLAN_1_PERSISTENT_DISK_TYPE" \
    '
    {
     ".rabbitmq-server.server_admin_credentials": {
        "value": {
          "identity": $tile_rabbit_admin_user,
          "password": $tile_rabbit_admin_passwd
        }
      },
      ".properties.syslog_selector": {
        "value": "disabled"
      },
      ".properties.disk_alarm_threshold": {
        "value": "mem_relative_1_0"
      },
      ".rabbitmq-broker.dns_host": {
        "value": $tile_rabbit_proxy_vip
      },
      ".rabbitmq-haproxy.static_ips": {
        "value": $tile_rabbit_proxy_ips
      }
    }

    +

    if $has_odb_plan_1 != "0" then
       {
        ".properties.on_demand_broker_plan_1_cf_service_access": {
          "value": "enable"
        },
        ".properties.on_demand_broker_plan_1_instance_quota": {
          "value": $tile_rabbit_on_demand_plan_1_instance_quota
        },
        ".properties.on_demand_broker_plan_1_rabbitmq_az_placement": {
          "value": [ $tile_az_rabbit_singleton ]
        },
        ".properties.on_demand_broker_plan_1_disk_limit_acknowledgement": {
          "value": ["acknowledge"]
        }
      }

      +

      if $has_odb_plan_vm_type != "0" then
      {
        ".properties.on_demand_broker_plan_1_rabbitmq_vm_type": {
          "value": $tile_rabbit_odb_plan_1_vm_type
        }
      }
      else
      .
      end

      +
      if $has_odb_plan_disk_type != "0" then
      {
        ".properties.on_demand_broker_plan_1_rabbitmq_persistent_disk_type": {
          "value": $tile_rabbit_odb_plan_1_persistent_disk_type
        }
      }
      else
        .
      end

    elif $has_older_odb_dedicated_plan != "0" then
       {
        ".properties.on_demand_broker_dedicated_single_node_plan_cf_service_access": {
          "value": "enable"
        },
        ".properties.on_demand_broker_dedicated_single_node_plan_instance_quota": {
          "value": $tile_rabbit_on_demand_plan_1_instance_quota
        },
        ".properties.on_demand_broker_dedicated_single_node_plan_rabbitmq_az_placement": {
          "value": [ $tile_az_rabbit_singleton ]
        },
        ".properties.on_demand_broker_dedicated_single_node_plan_disk_limit_acknowledgement": {
          "value": ["acknowledge"]
        }
      }

      +

      if $has_odb_plan_vm_type != "0" then
      {
        ".properties.on_demand_broker_dedicated_single_node_plan_rabbitmq_vm_type": {
          "value": $tile_rabbit_odb_plan_1_vm_type
        }
      }
      else
      .
      end

      +

      if $has_odb_plan_disk_type != "0" then
      {
        ".properties.on_demand_broker_dedicated_single_node_plan_rabbitmq_persistent_disk_type": {
          "value": $tile_rabbit_odb_plan_1_persistent_disk_type
        }
      }
      else
        .
      end
    else
      .
    end
'
)

prod_resources=$(
  jq -n \
    --argjson tile_rabbit_proxy_instances $TILE_RABBIT_PROXY_INSTANCES \
    --argjson tile_rabbit_server_instances $TILE_RABBIT_SERVER_INSTANCES \
    '
    {
      "rabbitmq-haproxy": {
        "instance_type": {"id": "automatic"},
        "instances" : $tile_rabbit_proxy_instances
      },
      "rabbitmq-server": {
        "instance_type": {"id": "automatic"},
        "instances" : $tile_rabbit_server_instances
      }
    }
    '
)

om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k configure-product \
    -n $PRODUCT_NAME \
    -pn "$prod_network" \
    -pr "$prod_resources"

om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k configure-product \
    -n $PRODUCT_NAME \
    -p "$prod_properties"


# Set Errands to on Demand for 1.10
if [ "$IS_ERRAND_WHEN_CHANGED_ENABLED" == "true" ]; then
  echo "applying errand configuration"
  sleep 6
  RABBITMQ_ERRANDS=$(cat <<-EOF
{"errands":[
  {"name":"broker-registrar","post_deploy":"when-changed"}
  ]
}
EOF
)

  om -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
                              curl -p "/api/v0/staged/products/$PRODUCT_GUID/errands" \
                              -x PUT -d "$RABBITMQ_ERRANDS"
fi

# Proceed if NSX is enabled on Bosh Director
# Support NSX LBR Integration
# if nsx is not enabled, skip remaining steps
if [ "$IS_NSX_ENABLED" == "null" -o "$IS_NSX_ENABLED" == "" ]; then
  exit
fi



# $RABBITMQ_TILE_JOBS_REQUIRING_LBR comes filled by nsx-edge-gen list command
# Sample: ERT_TILE_JOBS_REQUIRING_LBR='mysql_proxy,tcp_router,router,diego_brain'
JOBS_REQUIRING_LBR=$RABBITMQ_TILE_JOBS_REQUIRING_LBR

# Change to pattern for grep
JOBS_REQUIRING_LBR_PATTERN=$(echo $JOBS_REQUIRING_LBR | sed -e 's/,/\\|/g')

# Get job guids for deployment (from staged product)
om \
    -t https://$OPS_MGR_HOST \
    -k -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs" 2>/dev/null \
                          | jq '.[] | .[] ' > /tmp/jobs_list.log

for job_guid in $(cat /tmp/jobs_list.log | jq '.guid' | tr -d '"')
do
  job_name=$(cat /tmp/jobs_list.log | grep -B1 $job_guid | grep name | awk -F '"' '{print $4}')
  job_name_upper=$(echo ${job_name^^} | sed -e 's/-/_/')

  # Check for security group defined for the given job from Env
  # Expecting only one security group env variable per job (can have a comma separated list)
  SECURITY_GROUP=$(env | grep "TILE_RABBIT_${job_name_upper}_SECURITY_GROUP" | awk -F '=' '{print $2}')

  match=$(echo $job_name | grep -e $JOBS_REQUIRING_LBR_PATTERN  || true)
  if [ "$match" != "" -o  "$SECURITY_GROUP" != "" ]; then
    echo "$job_name requires Loadbalancer or security group..."

    # Check if User has specified their own security group
    # Club that with an auto-security group based on product guid by Bosh
    # for grouping all vms with the same security group
    if [ "$SECURITY_GROUP" != "" ]; then
      SECURITY_GROUP="${SECURITY_GROUP},${PRODUCT_GUID}"
    else
      SECURITY_GROUP=${PRODUCT_GUID}
    fi

    # The associative array comes from sourcing the /tmp/jobs_lbr_map.out file
    # filled earlier by nsx-edge-gen list command
    # Sample associative array content:
    # ERT_TILE_JOBS_LBR_MAP=( ["mysql_proxy"]="$ERT_MYSQL_LBR_DETAILS" ["tcp_router"]="$ERT_TCPROUTER_LBR_DETAILS"
    # .. ["diego_brain"]="$SSH_LBR_DETAILS"  ["router"]="$ERT_GOROUTER_LBR_DETAILS" )
    # SSH_LBR_DETAILS=[diego_brain]="esg-sabha6:VIP-diego-brain-tcp-21:diego-brain21-Pool:2222"
    LBR_DETAILS=${RABBITMQ_TILE_JOBS_LBR_MAP[$job_name]}

    RESOURCE_CONFIG=$(om -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
                      curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs/${job_guid}/resource_config" \
                      2>/dev/null)
    #echo "Resource config : $RESOURCE_CONFIG"
    # Remove trailing brace to add additional elements
    # Remove also any empty nsx_security_groups
    # Sample RESOURCE_CONFIG with nsx_security_group comes middle with ','
    # { "instance_type": { "id": "automatic" },
    #   "instances": 1,
    #   "nsx_security_groups": null,
    #   "persistent_disk": { "size_mb": "1024" }
    # }
    # or nsx_security_group comes last without ','
    # { "instance_type": { "id": "automatic" },
    #   "instances": 1,
    #   "nsx_security_groups": null
    # }
    # Strip the ending brace and also "nsx_security_group": null


    nsx_lbr_payload_json='{ "nsx_lbs": [ ] }'

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
      #ENTRY="{ \"edge_name\": \"$edge_name\", \"pool_name\": \"$pool_name\", \"port\": \"$port\", \"monitor_port\": \"$monitor_port\", \"security_group\": \"$job_security_grp\" }"
      #echo "Created lbr entry for job: $job_guid with value: $ENTRY"

      ENTRY=$(jq -n \
                  --arg edge_name $edge_name \
                  --arg pool_name $pool_name \
                  --argjson port $port \
                  --arg monitor_port $monitor_port \
                  --arg security_group "$job_security_grp" \
                  '{
                     "edge_name": $edge_name,
                     "pool_name": $pool_name,
                     "port": $port,
                     "security_group": $security_group
                   }
                   +
                   if $monitor_port != null and $monitor_port != "None" then
                   {
                      "monitor_port": $monitor_port
                   }
                   else
                    .
                   end
              ')

      nsx_lbr_payload_json=$(echo $nsx_lbr_payload_json \
                                | jq --argjson new_entry "$ENTRY" \
                                '.nsx_lbs += [$new_entry] ')

      #index=$(expr $index + 1)
    done

    nsx_security_group_json=$(jq -n \
                              --arg nsx_security_groups $SECURITY_GROUP \
                              '{ "nsx_security_groups": ($nsx_security_groups | split(",") ) }')

    #echo "Job: $job_name with GUID: $job_guid and NSX_LBR_PAYLOAD : $NSX_LBR_PAYLOAD"
    echo "Job: $job_name with GUID: $job_guid has SG: $nsx_security_group_json and NSX_LBR_PAYLOAD : $nsx_lbr_payload_json"

    #UPDATED_RESOURCE_CONFIG=$(echo "$RESOURCE_CONFIG \"nsx_security_groups\": [ $SECURITY_GROUP ], $NSX_LBR_PAYLOAD }")
    UPDATED_RESOURCE_CONFIG=$( echo $RESOURCE_CONFIG \
                              | jq  \
                              --argjson nsx_lbr_payload "$nsx_lbr_payload_json" \
                              --argjson nsx_security_groups "$nsx_security_group_json" \
                              ' . |= . + $nsx_security_groups +  $nsx_lbr_payload ')
    echo "Job: $job_name with GUID: $job_guid and RESOURCE_CONFIG : $UPDATED_RESOURCE_CONFIG"

    # Register job with NSX Pool in Ops Mgr (gets passed to Bosh)
    om \
        -t https://$OPS_MGR_HOST \
        -k -u $OPS_MGR_USR \
        -p $OPS_MGR_PWD  \
        curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs/${job_guid}/resource_config"  \
        -x PUT  -d "${UPDATED_RESOURCE_CONFIG}" 2>/dev/null

    # final structure
    # {
    #   "instance_type": {
    #     "id": "automatic"
    #   },
    #   "instances": 1,
    #   "persistent_disk": {
    #     "size_mb": "automatic"
    #   },
    #   "nsx_security_groups": [
    #     "cf-a7e3e3f819a68a3ee869"
    #   ],
    #   "nsx_lbs": [
    #     {
    #       "edge_name": "esg-sabha-test",
    #       "pool_name": "tcp-router31-Pool",
    #       "security_group": "cf-a7e3e3f819a68a3ee869-tcp_router",
    #       "port": "5000"
    #     }
    #   ]
    # }

  fi
done

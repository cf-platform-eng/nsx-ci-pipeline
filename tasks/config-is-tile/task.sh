#!/bin/bash -e



export ROOT_DIR=`pwd`
source $ROOT_DIR/nsx-ci-pipeline/functions/copy_binaries.sh
source $ROOT_DIR/nsx-ci-pipeline/functions/check_versions.sh


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
check_installed_cf_version
check_available_product_version "p-isolation"

#check_installed_srt_version

# Can only support one version of the default isolation segment tile
# Search for the tile using the specified product name if available
# or search using p-iso as default iso product name

if [ -z "$PRODUCT_NAME" -o "$PRODUCT_NAME" == "p-isolation-segment" ]; then
  check_available_product_version "p-isolation-segment"
else
  check_available_product_version "p-isolation-segment-${PRODUCT_NAME}"
fi

om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k stage-product \
    -p $PRODUCT_NAME \
    -v $PRODUCT_VERSION 2>/dev/null 

check_staged_product_guid $PRODUCT_NAME


function fn_get_azs {
     local azs_csv=$1
     echo $azs_csv | awk -F "," -v braceopen='{' -v braceclose='}' -v name='"name":' -v quote='"' -v OFS='"},{"name":"' '$1=$1 {print braceopen name quote $0 quote braceclose}'
}

TILE_AVAILABILITY_ZONES=$(fn_get_azs $TILE_AZS_ISO)


# if [[ -z "$SSL_CERT" ]]; then
# DOMAINS=$(cat <<-EOF
#   {"domains": ["*.$SYSTEM_DOMAIN", "*.$APPS_DOMAIN", "*.login.$SYSTEM_DOMAIN", "*.uaa.$SYSTEM_DOMAIN"] }
# EOF
# )

#   CERTIFICATES=$(om \
#                   -t https://$OPS_MGR_HOST \
#                   -u $OPS_MGR_USR \
#                   -p $OPS_MGR_PWD  \
#                   -k curl -p "$OPS_MGR_GENERATE_SSL_ENDPOINT" \
#                   -x POST -d "$DOMAINS")

#   export SSL_CERT=`echo $CERTIFICATES | jq '.certificate' | tr -d '"'`
#   export SSL_PRIVATE_KEY=`echo $CERTIFICATES | jq '.key' | tr -d '"'`

#   echo "Using self signed certificates generated using Ops Manager..."

# fi

source $ROOT_DIR/nsx-ci-pipeline/functions/generate_cert.sh

if [[ -z "$SSL_CERT" ]]; then
  domains=(
    "*.${SYSTEM_DOMAIN}"
    "*.${APPS_DOMAIN}"
    "*.login.${SYSTEM_DOMAIN}"
    "*.uaa.${SYSTEM_DOMAIN}"
  )

  certificates=$(generate_cert "${domains[*]}")
  SSL_CERT=`echo $certificates | jq --raw-output '.certificate'`
  SSL_PRIVATE_KEY=`echo $certificates | jq --raw-output '.key'`
fi


if [[ -z "$SAML_SSL_CERT" ]]; then
  saml_cert_domains=(
    "*.${SYSTEM_DOMAIN}"
    "*.login.${SYSTEM_DOMAIN}"
    "*.uaa.${SYSTEM_DOMAIN}"
  )

  saml_certificates=$(generate_cert "${saml_cert_domains[*]}")
  SAML_SSL_CERT=$(echo $saml_certificates | jq --raw-output '.certificate')
  SAML_SSL_PRIVATE_KEY=$(echo $saml_certificates | jq --raw-output '.key')
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

is_network=$(
  jq -n \
    --arg network_name "$NETWORK_NAME" \
    --arg other_azs "$TILE_AZS_ISO" \
    --arg singleton_az "$TILE_AZ_ISO_SINGLETON" \
    '
    {
      "network": {
        "name": $network_name
      },
      "other_availability_zones": ($other_azs | split(",") | map({name: .})),
      "singleton_availability_zone": {
        "name": $singleton_az
      }
    }
    '    
    
)

# No C2C support in PCF 1.9, 1.10 and older versions
export SUPPORTS_C2C=false
if [ $PRODUCT_MAJOR_VERSION -le 1 ]; then
  if [ $PRODUCT_MINOR_VERSION -ge 11 ]; then
    export SUPPORTS_C2C=true   
  fi
else
  export SUPPORTS_C2C=true
fi


has_routing_disable_http=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.routing_disable_http" | wc -l || true)
has_haproxy_forward_tls=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.haproxy_forward_tls" | wc -l || true)
has_gorouter_ssl_ciphers=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.gorouter_ssl_ciphers" | wc -l || true)
has_haproxy_ssl_ciphers=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.haproxy_ssl_ciphers" | wc -l || true)

has_garden_network_mtu=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".isolated_diego_cell.garden_network_mtu" | wc -l || true)
has_garden_network_pool=$(echo $STAGED_PRODUCT_PROPERTIES | jq . |grep ".isolated_diego_cell.garden_network_pool" | wc -l || true)

has_cni_vtep_port=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.container_networking.enable.vtep_port" | wc -l || true)
has_cni_network_cidr=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".container_networking.enable.network_cidr" | wc -l || true)
has_c2c_enable_network=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties\.container_networking\.enable" | wc -l || true)
has_c2c_disable_network=$(echo $STAGED_PRODUCT_PROPERTIES | jq . |grep ".properties\.container_networking\.disable" | wc -l || true)

has_networking_poe_ssl_certs=$(echo $STAGED_PRODUCT_PROPERTIES | jq . |grep ".properties.networking_poe_ssl_certs" | wc -l || true)
has_networking_poe_ssl_single_cert=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties.networking_poe_ssl_cert" | grep -v ".properties.networking_poe_ssl_certs" | wc -l || true)


# following not yet used in Iso-segment tile
# has_cni_selection=$(echo $STAGED_PRODUCT_PROPERTIES | jq . | grep ".properties\.container_networking_interface_plugin" | wc -l || true)
# --arg supports_c2c  "$SUPPORTS_C2C" \
# --arg has_cni_selection "$has_cni_selection" \
# --arg tile_ert_enable_c2c "$TILE_ERT_ENABLE_C2C" \
# --arg tile_ert_c2c_network_cidr "$TILE_ERT_C2C_NETWORK_CIDR" \
# --arg tile_ert_c2c_vtep_port "$TILE_ERT_C2C_VTEP_PORT" \

is_properties=$(
  jq -n \
    --arg cell_disk_capacity "$CELL_DISK_CAPACITY" \
    --arg cell_memory_capacity "$CELL_MEMORY_CAPACITY" \
    --arg insecure_docker_registry_list "$INSECURE_DOCKER_REGISTRY_LIST" \
    --arg segment_name "$SEGMENT_NAME" \
    --arg haproxy_forward_tls "$HAPROXY_FORWARD_TLS" \
    --arg haproxy_backend_ca "$HAPROXY_BACKEND_CA" \
    --arg router_tls_ciphers "$ROUTER_TLS_CIPHERS" \
    --arg haproxy_tls_ciphers "$HAPROXY_TLS_CIPHERS" \
    --arg disable_http_proxy "$DISABLE_HTTP_PROXY" \
    --arg has_routing_disable_http "$has_routing_disable_http" \
    --arg has_haproxy_forward_tls "$has_haproxy_forward_tls" \
    --arg has_gorouter_ssl_ciphers "$has_gorouter_ssl_ciphers" \
    --arg has_haproxy_ssl_ciphers "$has_haproxy_ssl_ciphers" \
    --arg has_garden_network_mtu "$has_garden_network_mtu" \
    --arg application_network_mtu "$APPLICATION_NETWORK_MTU" \
    --arg has_garden_network_mtu "$has_garden_network_mtu" \
    --arg has_cni_vtep_port "$has_c2c_enable_network" \
    --arg has_cni_network_cidr "$has_c2c_enable_network" \
    --arg tile_iso_c2c_vtep_port "$TILE_ISO_C2C_VTEP_PORT" \
    --arg tile_iso_c2c_network_cidr "$TILE_ISO_C2C_NETWORK_CIDR" \
    --arg supports_c2c  "$SUPPORTS_C2C" \
    --arg tile_iso_enable_c2c "$TILE_ISO_ENABLE_C2C" \
    --arg has_c2c_enable_network "$has_c2c_enable_network" \
    --arg has_c2c_disable_network "$has_c2c_disable_network" \
    --arg has_networking_poe_ssl_certs "$has_networking_poe_ssl_certs" \
    --arg has_networking_poe_ssl_single_cert "$has_networking_poe_ssl_single_cert" \
    --arg cert_pem "$SSL_CERT" \
    --arg private_key_pem "$SSL_PRIVATE_KEY" \
    --arg has_garden_network_pool "$has_garden_network_pool" \
    --arg application_network_cidr "$APPLICATION_NETWORK_CIDR" \
    --arg is_nsx_enabled "$IS_NSX_ENABLED" \
    --arg router_static_ips "$ROUTER_STATIC_IPS" \
'
    {
      ".isolated_diego_cell.executor_disk_capacity": {
        "value": $cell_disk_capacity
      },
      ".isolated_diego_cell.executor_memory_capacity": {
        "value": $cell_memory_capacity
      },
      ".isolated_diego_cell.insecure_docker_registry_list": {
        "value": $insecure_docker_registry_list
      },
      ".isolated_diego_cell.placement_tag": {
        "value": $segment_name
      }
    }
    +

    # HAProxy Forward TLS
    if $has_haproxy_forward_tls != "0" then
      if $haproxy_forward_tls == "enable" then
      {
        ".properties.haproxy_forward_tls": {
          "value": "enable"
        },
        ".properties.haproxy_forward_tls.enable.backend_ca": {
          "value": $haproxy_backend_ca
        }
      }
      else
        {
          ".properties.haproxy_forward_tls": {
            "value": "disable"
          }
        }
      end
    else
    .
    end

    +

    if $has_routing_disable_http != "0" then
    {
      ".properties.routing_disable_http": {
        "value": $disable_http_proxy
      }
    }
    else
    .
    end

    +

    # TLS Cipher Suites
    if $has_gorouter_ssl_ciphers != "0" then
    {
      ".properties.gorouter_ssl_ciphers": {
        "value": $router_tls_ciphers
      },
      ".properties.haproxy_ssl_ciphers": {
        "value": $haproxy_tls_ciphers
      }
    }
    else
    .
    end

    +

    if $has_garden_network_mtu != "0" then {
        ".isolated_diego_cell.garden_network_mtu": {
        "value": $application_network_mtu
      }
    }
    else
    .
    end  

    +
    if $is_nsx_enabled == "" or $is_nsx_enabled == "None" then {
        ".isolated_router.static_ips": {
        "value": $router_static_ips
      }
    }
    else
    .
    end

    +
    if $has_cni_vtep_port != "0" then {
        ".properties.container_networking.enable.vtep_port": {
        "value": $tile_iso_c2c_vtep_port
      }
    }
    else
    .
    end

    +
    if $has_cni_network_cidr != "0" then {
        ".properties.container_networking.enable.network_cidr": {
        "value": $tile_iso_c2c_network_cidr
      }
    }
    else
    .
    end 

    +

    if $supports_c2c == "true" then 
      if $tile_iso_enable_c2c == "enable" and $has_c2c_enable_network != "0" then
       {
          ".properties.container_networking": {
              "value": "enable"
          },
          ".properties.container_networking.enable.network_cidr": {
              "value": $tile_iso_c2c_network_cidr
          },
          ".properties.container_networking.enable.vtep_port": {
            "value": $tile_iso_c2c_vtep_port
          }
       }
      elif $tile_iso_enable_c2c == "disable" and $has_c2c_disable_network != "0" then
      {
        ".properties.container_networking": {
            "value": "disable"
        },
        ".properties.container_networking.disable.garden_network_pool": {
            "value": "10.254.0.0/22"
        }
      }
      else
      .
      end

    else
      if $has_garden_network_pool != "0" then
        {
          ".isolated_diego_cell.garden_network_pool": {
            "value": $application_network_cidr
          }
        }
      else
      .
      end
    end

    + if $has_networking_poe_ssl_certs != "0" then
    {
      ".properties.networking_poe_ssl_certs": {
        "value": [ 
          {
            "name": "certificate",
            "certificate": {
              "cert_pem": $cert_pem,
              "private_key_pem": $private_key_pem
            }
          } 
        ]
      }
    }
    elif $has_networking_poe_ssl_single_cert != "0" then
    {
      ".properties.networking_poe_ssl_cert": {
        "value": {
          "cert_pem": $cert_pem,
          "private_key_pem": $private_key_pem
        }
      }
    }
    else
    .
    end


'
)


# End of PROPERTIES block

is_resources=$(
  jq -n \
   --argjson is_router_instances $IS_ROUTER_INSTANCES \
   --argjson is_diego_cell_instances $IS_DIEGO_CELL_INSTANCES \
'
{
  "isolated_router": {
    "instance_type": {"id": "automatic"},
    "instances" : $is_router_instances
  },
  "isolated_diego_cell": {
    "instance_type": {"id": "automatic"},
    "instances" : $is_diego_cell_instances
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
    -p "$is_properties" \
    -pn "$is_network" \
    -pr "$is_resources"

has_networking_poe_terminate=$(echo $STAGED_PRODUCT_PROPERTIES | jq . |grep ".properties.networking_point_of_entry.terminate" | wc -l || true)

ssl_properties=$( jq -n \
    --arg has_networking_poe_terminate "$has_networking_poe_terminate" \
    --arg ssl_termination_point "$SSL_TERMINATION_POINT" \
    --arg ssl_cert "$SSL_CERT" \
    --arg ssl_private_key "$SSL_PRIVATE_KEY" \
    --arg router_ssl_ciphers "$ROUTER_SSL_CIPHERS" \
'
  {
      ".properties.networking_point_of_entry": {
        "value": $ssl_termination_point
      }
  }
  +
  if $has_networking_poe_terminate != "0" then
    if $ssl_termination_point == "terminate_at_router" then
    # Terminating SSL at the goRouters and using self signed/provided certs... 
    {
      ".properties.networking_point_of_entry.terminate_at_router.ssl_rsa_certificate": {
        "value": {
          "cert_pem": $ssl_cert,
          "private_key_pem": $ssl_private_key
        }
      },
      ".properties.networking_point_of_entry.terminate_at_router.ssl_ciphers": {
        "value": $router_ssl_ciphers
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

om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k configure-product \
    -n $PRODUCT_NAME \
    -p "$ssl_properties"

# if nsx is not enabled, skip remaining steps
if [ "$IS_NSX_ENABLED" == "null" -o "$IS_NSX_ENABLED" == "" ]; then
  exit
fi

# Proceed if NSX is enabled on Bosh Director
# Support NSX LBR Integration

# $ISO_TILE_JOBS_REQUIRING_LBR comes filled by nsx-edge-gen list command
# Sample: ERT_TILE_JOBS_REQUIRING_LBR='mysql_proxy,tcp_router,router,diego_brain'
JOBS_REQUIRING_LBR=$ISO_TILE_JOBS_REQUIRING_LBR

# Change to pattern for grep
JOBS_REQUIRING_LBR_PATTERN=$(echo $JOBS_REQUIRING_LBR | sed -e 's/,/\\|/g')

# Get job guids for deployment (from staged product)
om \
    -t https://$OPS_MGR_HOST \
    -u $OPS_MGR_USR \
    -p $OPS_MGR_PWD  \
    -k curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs" \
    2>/dev/null \
    | jq '.[] | .[] ' > /tmp/jobs_list.log

for job_guid in $(cat /tmp/jobs_list.log | jq '.guid' | tr -d '"')
do

  job_name=$(cat /tmp/jobs_list.log | grep -B1 $job_guid | grep name | awk -F '"' '{print $4}')
  job_name_upper=$(echo ${job_name^^} | sed -e 's/-/_/')
  
  # Check for security group defined for the given job from Env
  # Expecting only one security group env variable per job (can have a comma separated list)
  SECURITY_GROUP=$(env | grep "TILE_ISO_${job_name_upper}_SECURITY_GROUP" | awk -F '=' '{print $2}')

  match=$(echo $job_name | grep -e $JOBS_REQUIRING_LBR_PATTERN  || true)
  if [ "$match" != "" -o "$SECURITY_GROUP" != "" ]; then
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
                              '{ "nsx_security_groups": [  ($nsx_security_groups | split(",") ) ] }')

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
        -u $OPS_MGR_USR \
        -p $OPS_MGR_PWD  \
        -k curl -p "/api/v0/staged/products/${PRODUCT_GUID}/jobs/${job_guid}/resource_config"  \
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

#!/bin/bash

export ROOT_DIR=`pwd`
export SCRIPT_DIR=$(dirname $0)
export NSX_GEN_OUTPUT_DIR=${ROOT_DIR}/nsx-gen-output
export NSX_GEN_OUTPUT=${NSX_GEN_OUTPUT_DIR}/nsx-gen-out.log
export NSX_GEN_UTIL=${NSX_GEN_OUTPUT_DIR}/nsx_parse_util.sh

if [ -e "${NSX_GEN_OUTPUT}" ]; then
  #echo "Saved nsx gen output:"
  #cat ${NSX_GEN_OUTPUT}
  source ${NSX_GEN_UTIL} ${NSX_GEN_OUTPUT}
else
  echo "Unable to retreive nsx gen output generated from previous nsx-gen-list task!!"
  exit 1
fi

CERTIFICATES=`om -t https://opsmgr.homelab.io -u admin -p welcome -k curl -p "/api/v0/certificates" -x POST -d '{"domains": ["*.sys.homelab.io", "*.cfapps.homelab.io", "*.login.sys.homelab.io", "*.uaa.sys.homelab.io"] }'`

CERT_PEM=`echo $CERTIFICATES | jq '.certificate'`

PRIVATE_KEY=`echo $CERTIFICATES | jq '.key'`

PROPERTIES_CONFIG=$(cat <<-EOF
{
  ".properties.networking_point_of_entry": {
    "value": "terminate_at_router"
  },
  ".properties.networking_point_of_entry.terminate_at_router.ssl_rsa_certificate": {
    "value": {
      "private_key_pem": "${PRIVATE_KEY}",
      "cert_pem": "${CERT_PEM}"
    }
  },
  ".router.static_ips": {
    "value": "${ISOZONE_SWITCH_1_GOROUTER_STATIC_IPS}"
  },
  ".isolated_diego_cell.garden_network_pool": {
    "value": "10.254.0.0/22"
  },
  ".isolated_diego_cell.placement_tag": {
    "value": "${PLACEMENT_TAG_NAME}"
  }
}
EOF
)

RESOURCE_CONFIG=$(cat <<-EOF
{
  "router": {
    "instance_type": {"id": "automatic"},
    "instances" : 1
  },
  "isolated_diego_cell": {
    "instance_type": {"id": "automatic"},
    "instances" : 1
  }
}
EOF
)

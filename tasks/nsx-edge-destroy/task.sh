#!/bin/bash
set -ex

export ROOT_DIR=`pwd`
export SCRIPT_DIR=$(dirname $0)

pushd nsx-edge-gen  >/dev/null 2>&1

# Remove any existing config file template from the repo
if [[ -e nsx_cloud_config.yml ]]; then rm -rf nsx_cloud_config.yml; fi

# Init new config file template
./nsx-gen/bin/nsxgen -i $NSX_EDGE_GEN_NAME init

./nsx-gen/bin/nsxgen \
-c "$NSX_EDGE_GEN_NAME" \
-esg_name_1 "$NSX_EDGE_GEN_NAME" \
-esg_ospf_password_1 "$ESG_OSPF_PASSWORD_1"  \
-esg_cli_user_1 "$ESG_CLI_USERNAME_1"   \
-esg_cli_pass_1 "$ESG_CLI_PASSWORD_1"   \
-esg_ert_certs_1 "$ESG_ERT_CERTS_NAME_1"   \
-esg_opsmgr_uplink_ip_1 $ESG_OPSMGR_UPLINK_IP_1   \
-esg_go_router_uplink_ip_1 $ESG_GO_ROUTER_UPLINK_IP_1   \
-esg_diego_brain_uplink_ip_1 $ESG_DIEGO_BRAIN_UPLINK_IP_1   \
-esg_tcp_router_uplink_ip_1 $ESG_TCP_ROUTER_UPLINK_IP_1   \
-esg_gateway_1 $ESG_GATEWAY_1 \
-vcenter_addr "$VCENTER_HOST"   \
-vcenter_user "$VCENTER_USR"   \
-vcenter_pass "$VCENTER_PWD"   \
-vcenter_dc "$VCENTER_DATA_CENTER"   \
-vcenter_ds "$NSX_EDGE_GEN_EDGE_DATASTORE"   \
-vcenter_cluster "$NSX_EDGE_GEN_EDGE_CLUSTER"  \
-nsxmanager_addr "$NSX_EDGE_GEN_NSX_MANAGER_ADDRESS"  \
-nsxmanager_user "$NSX_EDGE_GEN_NSX_MANAGER_ADMIN_USER"   \
-nsxmanager_pass "$NSX_EDGE_GEN_NSX_MANAGER_ADMIN_PASSWD"   \
-nsxmanager_tz "$NSX_EDGE_GEN_NSX_MANAGER_TRANSPORT_ZONE"   \
-nsxmanager_tz_clusters "$NSX_EDGE_GEN_NSX_MANAGER_TRANSPORT_ZONE_CLUSTERS" \
-nsxmanager_dportgroup "$NSX_EDGE_GEN_NSX_MANAGER_DISTRIBUTED_PORTGROUP" \
-nsxmanager_uplink_ip "$ESG_DEFAULT_UPLINK_IP_1"  \
-nsxmanager_uplink_port "$ESG_DEFAULT_UPLINK_PG_1" \
-nsxmanager_en_dlr "$NSX_EDGE_GEN_ENABLE_DLR" \
-nsxmanager_bosh_nsx_enabled "$NSX_EDGE_GEN_BOSH_NSX_ENABLED" \
delete

STATUS=$?
popd  >/dev/null 2>&1

exit $STATUS

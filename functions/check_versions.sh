#!/bin/bash

function check_bosh_version {  

  om-linux -t "https://${OPS_MGR_HOST}" \
          -u "$OPS_MGR_USR" \
          -p "$OPS_MGR_PWD" \
          -k upload-stemcell -s $SC_FILE_PATH

  export BOSH_PRODUCT_VERSION=$(om-linux \
                                  -t "https://${OPS_MGR_HOST}" \
                                  -u "$OPS_MGR_USR" \
                                  -p "$OPS_MGR_PWD" \
                                  -k curl -p "/api/v0/deployed/products" \
                                  2>/dev/null \
                                  | jq '.[] | select(.installation_name=="p-bosh") | .product_version' \
                                  | tr -d '"')
  export BOSH_MAJOR_VERSION=$(echo $BOSH_PRODUCT_VERSION | awk -F '.' '{print $1}' )
  export BOSH_MINOR_VERSION=$(echo $BOSH_PRODUCT_VERSION | awk -F '.' '{print $2}' | sed -e 's/-.*//g' )

  echo "$BOSH_PRODUCT_VERSION"
}

function check_product_version {

  local product_code="$1"
  TILE_RELEASE=$(om-linux \
                    -t "https://${OPS_MGR_HOST}" \
                    -u "$OPS_MGR_USR" \
                    -p "$OPS_MGR_PWD" \
                    -k available-products \
                    | grep $product_code)

  export PRODUCT_NAME=$(echo $TILE_RELEASE | cut -d"|" -f2 | tr -d " ")
  export PRODUCT_VERSION=$(echo $TILE_RELEASE | cut -d"|" -f3 | tr -d " ")
  export PRODUCT_MAJOR_VERSION=$(echo $PRODUCT_VERSION | awk -F '.' '{print $1}' )
  export PRODUCT_MINOR_VERSION=$(echo $PRODUCT_VERSION | awk -F '.' '{print $2}' | sed -e 's/-.*//g' )

  echo "$PRODUCT_VERSION"
}

function check_staged_product_guid {

  local product_code="$1"
  PRODUCT_GUID=$(om-linux \
                  -t https://$OPS_MGR_HOST \
                  -u $OPS_MGR_USR \
                  -p $OPS_MGR_PWD \
                  -k curl -p "/api/v0/staged/products" \
                  -x GET \
                  | jq '.[] | select(.installation_name | contains("$product_code")) | .guid' \
                  | tr -d '"')

  echo "$PRODUCT_GUID"
}

function check_installed_cf_version {

  export CF_PRODUCT_VERSION=$(om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
            curl -p "/api/v0/staged/products" -x GET | jq '.[] | select(.installation_name | contains("cf-")) | .product_version' | tr -d '"')

  export CF_MAJOR_VERSION=$(echo $cf_product_version | awk -F '.' '{print $1}' )
  export CF_MINOR_VERSION=$(echo $cf_product_version | awk -F '.' '{print $2}' | sed -e 's/-.*//g')

  echo "$CF_PRODUCT_VERSION"

}

function check_installed_srt_version {

  export SRT_PRODUCT_VERSION=$(om-linux -t https://$OPS_MGR_HOST -k -u $OPS_MGR_USR -p $OPS_MGR_PWD \
            curl -p "/api/v0/staged/products" -x GET | jq '.[] | select(.installation_name | contains("srt-")) | .product_version' | tr -d '"')

  export SRT_MAJOR_VERSION=$(echo $cf_product_version | awk -F '.' '{print $1}' )
  export SRT_MINOR_VERSION=$(echo $cf_product_version | awk -F '.' '{print $2}' | sed -e 's/-.*//g')
  echo "$SRT_PRODUCT_VERSION"
}

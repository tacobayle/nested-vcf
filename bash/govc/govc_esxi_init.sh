load_govc_esxi () {
  unset GOVC_USERNAME
  unset GOVC_PASSWORD
  unset GOVC_DATACENTER
  unset GOVC_URL
  unset GOVC_DATASTORE
  unset GOVC_CLUSTER
  unset GOVC_INSECURE
  export GOVC_PASSWORD=$(jq -c -r .generic_password $jsonFile)
  export GOVC_INSECURE=true
  export GOVC_URL=${ip_esxi}
  export GOVC_USERNAME=root
}
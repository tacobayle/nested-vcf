load_govc_env_with_cluster () {
  export GOVC_USERNAME="${vsphere_nested_username}@${ssoDomain}"
  export GOVC_PASSWORD=${generic_password}
  export GOVC_DATACENTER=${vcsa_mgmt_dc}
  export GOVC_DATASTORE=${vcsa_mgmt_datastore}
  export GOVC_INSECURE=true
  export GOVC_URL=${vcsa_fqdn}
  export GOVC_CLUSTER=${vcsa_mgmt_cluster}
}
load_govc_nested_env_wo_cluster () {
  export GOVC_USERNAME="${vsphere_nested_username}@${ssoDomain}"
  export GOVC_PASSWORD=${generic_password}
  export GOVC_DATACENTER="${basename_sddc}-dc"
  export GOVC_INSECURE=true
  export GOVC_URL="${basename_sddc}-vcsa.${domain}"
  unset GOVC_CLUSTER
}
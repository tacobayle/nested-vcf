#!/bin/bash
#
source /nested-vcf/bash/govc/govc_init.sh
#
vsphere_host="$(jq -r .vsphere_underlay.vcsa $jsonFile)"
vsphere_username="$(jq -r .vsphere_underlay.username $jsonFile)"
vcenter_domain=""
vsphere_password="$(jq -r .vsphere_underlay.password $jsonFile)"
vsphere_dc="$(jq -r .vsphere_underlay.datacenter $jsonFile)"
vsphere_cluster="$(jq -r .vsphere_underlay.cluster $jsonFile)"
vsphere_datastore="$(jq -r .vsphere_underlay.datastore $jsonFile)"
#
load_govc
#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/load_govc_env_with_cluster.sh
source /home/ubuntu/avi/avi_api.sh
#
# ansible collection install vmware.alb
#
/home/ubuntu/.local/bin/ansible-galaxy collection install vmware.alb
#
# creating a content library and folder for seg
#
load_govc_env_with_cluster
govc about
if [ $? -ne 0 ] ; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to connect to vCenter" "${log_file}" "${slack_webhook}" "${google_webhook}"
  exit
fi
#
rm -f /tmp/cl_state
govc library.ls -json | jq -c -r '.[]' | while read cl
do
   if [[ $(echo ${cl} | jq -c -r '.name') == ${avi_content_library_name} ]]; then
     echo $(echo ${cl} | jq -c -r '.id') > /tmp/cl_state
   fi
done
if [ ! -f "/tmp/cl_state" ]; then
  content_library_id=$(govc library.create ${avi_content_library_name})
else
  content_library_id=$(cat /tmp/cl_state)
fi
#
# Avi HTTPS check
#
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_avi})
do
  log_message "  +++ Attempt ${count}: Waiting for Avi ctrl at https://${ip_avi} to be reachable..." "${log_file}" "" ""
  sleep 10
  count=$((count+1))
    if [[ "${count}" -eq 60 ]]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: Unable to connect to Avi ctrl at https://${ip_avi}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit
    fi
done
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi ctrl reachable at https://${ip_avi}" "${log_file}" "" ""
#
# VCF 9.1 config use case
#
if [[ ${vcf_version_two_digit} == "9.1" ]]; then
  date_index=$(date '+%Y%m%d%H%M%S')
  avi_cookie_file="/tmp/$(basename $0 | cut -d"." -f1)_${date_index}_cookie.txt"
  fqdn=${ip_avi}
  username='admin'
  password=''${generic_password}''
  #
  # retrieving version from sddcm
  #
  sddcm="${basename_sddc}-sddcm.${domain}"
  sddcmuser="${vsphere_nested_username}@${ssoDomain}"
  sddcmpass=''${generic_password}''
  loginpayload=$(printf '{"username" : "%s","password": "%s"}' $sddcmuser $sddcmpass)
  sddcm_token=$(curl -s -H 'Content-Type:application/json' https://$sddcm/v1/tokens -d "$loginpayload" -k | jq -c -r .'accessToken')
  if [ -z "$sddcm_token" ] || [ "$sddcm_token" == "null" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, avi config: sddcm_token is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
  avi_version=$(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/bundles" | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .version' | cut -d"-" -f1)
  #
  # API auth
  #
  curl_login=$(curl -s -k -X POST -H "Content-Type: application/json" \
                                  -d "{\"username\": \"${username}\", \"password\": \"${password}\"}" \
                                  -c ${avi_cookie_file} https://${fqdn}/login)
  csrftoken=$(cat ${avi_cookie_file} | grep csrftoken | awk '{print $7}')
  if [ -z "$csrftoken" ] || [ "$csrftoken" == "null" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, avi config: csrftoken is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
  #
  # user for backup
  #
  json_data='
      {
        "name": "ubuntu",
        "password": "'${generic_password}'"
      }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/cloudconnectoruser"
  cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.uuid')
  #
  # config backup and passphrase
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/backupconfiguration"
  backupconfiguration_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
  json_data='
      {
        "replace": {
          "name": "Backup-Configuration",
          "backup_passphrase": "'${generic_password}'",
          "save_local": true,
          "upload_to_remote_host": true,
          "remote_directory": "/home/ubuntu/avi/backup",
          "remote_file_transfer_protocol": "SCP",
          "remote_hostname": "'${ip_gw}'",
          "ssh_user_ref": "'${cloudconnectoruser_uuid}'"
        }
      }'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/backupconfiguration/${backupconfiguration_uuid}"
  #
  # system config.
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/systemconfiguration"
  json_data=$(echo ${response_body} | jq -c -r '. += {"welcome_workflow_complete": true}')
  avi_api 2 2 "PUT" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/systemconfiguration"
  #
  # cloud update
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/cloud"
  cloud_uuid=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .uuid')
  cloud_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .url')
  nsx_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .nsxt_configuration.nsxt_url')
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/cloudconnectoruser"
  nsx_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("nsxt_credentials")) | .uuid')
  vcenter_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("vcenter_credentials")) | .uuid')
  json_data='
    {
    "host": "'${nsx_url}'",
    "credentials_uuid": "'${nsx_cloudconnectoruser_uuid}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/nsxt/transportzones"
  tz_id=$(echo ${response_body} | jq -c -r --arg arg "VCF-Created-Overlay-Zone" '.resource.nsxt_transportzones[] | select(.name == $arg) | .id')
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/nsxt/tier1s"
  t1_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg $(echo ${segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .tier1') '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')
  t1_vip_name=$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .tier1')
  t1_vip_id=$(echo ${response_body} | jq -c -r --arg arg $(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .tier1') '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')
  json_data='
    {
    "host": "'${nsx_url}'",
    "credentials_uuid": "'${nsx_cloudconnectoruser_uuid}'",
    "transport_zone_id": "'${tz_id}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/nsxt/segments"
  seg_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg $(echo ${segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .display_name') '.resource.nsxt_segments[] | select(.name == $arg) | .id')
  seg_vip_id=$(echo ${response_body} | jq -c -r --arg arg $(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name') '.resource.nsxt_segments[] | select(.name == $arg) | .id')
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/vcenterserver"
  vcenter_server_uuid=$(echo ${response_body} | jq -c -r .'results[0].uuid')
  vcenter_server_url=$(echo ${response_body} | jq -c -r .'results[0].vcenter_url')
  json_data='
    {
    "host": "'${vcenter_server_url}'",
    "credentials_uuid": "'${vcenter_cloudconnectoruser_uuid}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/vcenter/contentlibraries"
  content_library_id=$(echo ${response_body} | jq -c -r --arg arg  ${avi_content_library_name} '.resource.vcenter_clibs[] | select(.name == $arg) | .id')
  #
  # add content library id
  #
  json_data='
      {
        "add":
        {
          "content_lib":
          {
            "id": "'${content_library_id}'"
          }
        }
      }'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/vcenterserver/${vcenter_server_uuid}"
  #
  # cloud update
  #
  json_data='
      {
        "add":
        {
          "nsxt_configuration":
          {
            "management_network_config":
            {
              "tz_type": "OVERLAY",
              "transport_zone": "'${tz_id}'",
              "overlay_segment":
              {
                "tier1_lr_id": "'${t1_mgmt_id}'",
                "segment_id": "'${seg_mgmt_id}'"
              }
            },
            "data_network_config":
            {
              "tz_type": "OVERLAY",
              "transport_zone": "'${tz_id}'",
              "tier1_segment_config":
              {
                "segment_config_mode": "TIER1_SEGMENT_MANUAL",
                "manual":
                {
                  "tier1_lrs":
                  [
                    {
                      "tier1_lr_id": "'${t1_vip_id}'",
                      "segment_id": "'${seg_vip_id}'"
                    }
                  ]
                }
              }
            }
          }
        }
      }'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/cloud/${cloud_uuid}"
  #
  # DNS profile
  #
  json_data='
    {
      "name": "dns-avi",
      "type": "IPAMDNS_TYPE_INTERNAL_DNS",
      "internal_profile":
      {
        "dns_service_domain":
        [
          {
            "domain_name": "'${avi_subdomain}'.'${domain}'"
          }
        ]
      }
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/ipamdnsproviderprofile"
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: configure Avi - waiting for 120 seconds" "${log_file}" "" ""
  sleep 120
  curl_login=$(curl -s -k -X POST -H "Content-Type: application/json" \
                                  -d "{\"username\": \"${username}\", \"password\": \"${password}\"}" \
                                  -c ${avi_cookie_file} https://${fqdn}/login)
  csrftoken=$(cat ${avi_cookie_file} | grep csrftoken | awk '{print $7}')
  #
  # IPAM profile
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/network"
  vip_uuid=$(echo ${response_body} | jq -c -r --arg arg $(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name') '.results[] | select(.name == $arg) | .uuid')
  json_data='
    {
      "name": "ipam-avi",
      "type": "IPAMDNS_TYPE_INTERNAL",
      "internal_profile":
      {
        "usable_networks": [{"nw_ref": "/api/network/'${vip_uuid}'" }]
      }
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/ipamdnsproviderprofile"
  #
  # Cloud update
  #
  json_data='
      {
        "add":
        {
          "ipam_provider_ref": "/api/ipamdnsproviderprofile/?name=ipam-avi",
          "dns_provider_ref": "/api/ipamdnsproviderprofile/?name=dns-avi"
        }
      }'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/cloud/${cloud_uuid}"
  #
  # Network update
  #
  json_data='
      {
        "add":
        {
          "dhcp_enabled": true,
          "exclude_discovered_subnets": true,
          "configured_subnets":
          [
            {
              "prefix":
              {
                "ip_addr":
                {
                  "addr": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr' | cut -d"/" -f1)'",
                  "type": "V4"
                },
                "mask": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr' | cut -d"/" -f2)'"
              },
              "static_ip_ranges":
              [
                {
                  "type": "STATIC_IPS_FOR_VIP",
                  "range":
                  {
                    "begin":
                    {
                      "addr": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.pool' | cut -d"-" -f1)'",
                      "type": "V4"
                    },
                    "end":
                    {
                      "addr": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.pool' | cut -d"-" -f2)'",
                      "type": "V4"
                    }
                  }
                }
              ]
            }
          ]
        }
      }'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/network/${vip_uuid}"
  #
  # Pulse registration
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/albservices/status"
  json_data='
    {
      "jwt_token": "'${avi_jwt_token=}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/portal/refresh-access-token"
  sleep 20
  random_string=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
  json_data='
    {
      "name": "workshop-demo-'${random_string}'",
      "description": "Registration and deregistration",
      "email": "avi.workshop@broadcom.com",
      "account_id": "'${avi_account_id}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/albservices/register"
  sleep 10
  #
  # SEG update
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/serviceenginegroup?name=Default-Group&cloud_ref=${cloud_uuid}"
  serviceneginegroup_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
  json_data='{"replace": {"cpu_reserve": false, "mem_reserve": false, "se_deprovision_delay": 120, "buffer_se": 0, "min_scaleout_per_vs": 1, "algo": "PLACEMENT_ALGO_PACKED", "ha_mode": "HA_MODE_SHARED", "vcpus_per_se": 1, "memory_per_se": 2048, "disk_per_se": 15, "realtime_se_metrics": {"duration": 30, "enable": false}}}'
  avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/serviceenginegroup/${serviceneginegroup_uuid}"
  #
  # DNS vsvip
  #
  json_data='
    {
      "cloud_ref": "'${cloud_url}'",
      "dns_info": [
        {
          "algorithm": "DNS_RECORD_RESPONSE_CONSISTENT_HASH",
          "fqdn": "dns.'${avi_subdomain}'.'${domain}'",
          "ttl": 30,
          "type": "DNS_RECORD_A"
        }
      ],
      "name": "dns-VsVip",
      "vip": [
        {
          "auto_allocate_ip": true,
          "ipam_network_subnet": {
            "network_ref": "/api/network/'${vip_uuid}'",
            "subnet": {
              "ip_addr": {
                "addr": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr' | cut -d"/" -f1)'",
                "type": "V4"
              },
              "mask": "'$(echo ${segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr' | cut -d"/" -f2)'"
            }
          }
        }
      ],
      "vrf_context_ref": "/api/vrfcontext/?name='${t1_vip_name}'"
    }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/vsvip"
  vsvip_url=$(echo ${response_body} | jq -c -r '.url')
  #
  # DNS VS
  #
  json_data='
  {
    "cloud_ref": "'${cloud_url}'",
    "name": "dns-vs",
    "vsvip_ref": "'${vsvip_url}'",
    "application_profile_ref": "/api/applicationprofile/?name=System-DNS",
    "network_profile_ref": "/api/networkprofile/?name=System-UDP-Per-Pkt",
    "services": [{"port": 53, "enable_ssl": false}]
  }'
  avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/virtualservice"
  #
  # Update system. config with DNS VS
  #
  avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/systemconfiguration"
  json_data=$(echo ${response_body} | jq -c -r '. += {"dns_virtualservice_refs": ["/api/virtualservice/?name=dns-vs"]}')
  avi_api 2 2 "PUT" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/systemconfiguration"
  #
  # checking DNS VS status
  #
  count=1
  response_body=""
  until [[ $(echo ${response_body} | jq -c -r '.results[0].runtime.oper_status.state') == "OPER_UP" ]]
  do
    avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/virtualservice-inventory"
    sleep 10
    count=$((count+1))
      if [[ "${count}" -eq 60 ]]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: Unable to get the DNS VS UP" "${log_file}" "${slack_webhook}" "${google_webhook}"
        exit 100
      fi
  done
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: DNS VS UP" "${log_file}" "${slack_webhook}" "${google_webhook}"
fi
if [[ ${vcf_version_two_digit} == "9.0" || ${vcf_version_two_digit} == "8.0U3b" ]]; then
  #
  # Network mgmt
  #
  network_management=$(echo ${segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true)')
  #
  # templating yaml file
  #
  sed -e "s/\${controllerPrivateIp}/${ip_avi}/" \
      -e "s/\${ntp}/${ip_gw}/" \
      -e "s/\${dns}/${ip_gw}/" \
      -e "s/\${ip_backup_server}/${ip_gw_vm_management}/" \
      -e "s/\${backup_password}/${generic_password}/" \
      -e "s/\${avi_username}/admin/" \
      -e "s/\${avi_password}/${generic_password}/" \
      -e "s/\${avi_old_password}/${avi_old_password}/" \
      -e "s/\${avi_version}/${avi_version}/" \
      -e "s/\${nsx_username}/admin/" \
      -e "s/\${nsx_password}/${generic_password}/" \
      -e "s/\${nsx_server}/${ip_nsx_vip}/" \
      -e "s/\${vsphere_username}/${vsphere_nested_username}@${ssoDomain}/" \
      -e "s/\${vsphere_password}/${generic_password}/" \
      -e "s/\${vsphere_server}/${vcsa_fqdn}/" \
      -e "s@\${import_sslkeyandcertificate_ca}@$(echo ${import_sslkeyandcertificate_ca} | jq -c -r '.')@" \
      -e "s@\${certificatemanagementprofile}@$(echo ${certificatemanagementprofile} | jq -c -r '.')@" \
      -e "s@\${alertscriptconfig}@$(echo ${alertscriptconfig} | jq -c -r '.')@" \
      -e "s@\${actiongroupconfig}@$(echo ${actiongroupconfig} | jq -c -r '.')@" \
      -e "s@\${alertconfig}@$(echo ${alertconfig} | jq -c -r '.')@" \
      -e "s@\${sslkeyandcertificate}@$(echo ${sslkeyandcertificate} | jq -c -r '.')@" \
      -e "s@\${sslkeyandcertificate_ref}@my-new-self-signed@" \
      -e "s@\${applicationprofile}@$(echo ${applicationprofile} | jq -c -r '.')@" \
      -e "s@\${vsdatascriptset}@$(echo ${vsdatascriptset} | jq -c -r '.')@" \
      -e "s@\${httppolicyset}@$(echo ${httppolicyset} | jq -c -r '.')@" \
      -e "s@\${roles}@$(echo "${roles}" | jq -c -r '.')@" \
      -e "s@\${tenants}@$(echo "${tenants}" | jq -c -r '.')@" \
      -e "s@\${users}@$(echo "${users}" | jq -c -r '.')@" \
      -e "s@\${cloud_name}@${nsx_cloud_name}@" \
      -e "s@\${cloud_obj_name_prefix}@${cloud_obj_name_prefix}@" \
      -e "s@\${vpc_mode}@true@" \
      -e "s@\${domain}@${avi_subdomain}.${domain}@" \
      -e "s@\${transport_zone_name}@${avi_nsx_transport_zone}@" \
      -e "s@\${network_management}@$(echo ${segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true)')@" \
      -e "s@\${networks_data}@$(echo ${segments_overlay} | jq -c -r '[.[] | select(has("avi_ipam_vip"))]')@" \
      -e "s@\${content_library_name}@${avi_content_library_name}@" \
      -e "s@\${service_engine_groups}@$(echo "${service_engine_groups}" | jq -c -r '.')@" \
      -e "s@\${network_services}@$(echo "${network_services}" | jq -c -r '.')@" \
      -e "s@\${pools}@$(echo ${pools} | jq -c -r '.')@" \
      -e "s@\${pool_groups}@$(echo ${pool_groups} | jq -c -r '.')@" \
      -e "s@\${virtual_services}@$(echo ${virtual_services} | jq -c -r '.')@" /home/ubuntu/templates/values_nsx.yaml.template | tee /home/ubuntu/avi/avi_values.yml
  #
  # starting ansible configuration
  #
  cd avi
  git clone ${avi_ansible_config_repo} --branch ${avi_ansible_config_tag}
  cd $(basename ${avi_ansible_config_repo})
  echo '---' | tee hosts_avi
  echo 'all:' | tee -a hosts_avi
  echo '  children:' | tee -a hosts_avi
  echo '    controller:' | tee -a hosts_avi
  echo '      hosts:' | tee -a hosts_avi
  echo '        '${ip_avi}':' | tee -a hosts_avi
  /home/ubuntu/.local/bin/ansible-playbook -i hosts_avi ${avi_ansible_playbook} --extra-vars @/home/ubuntu/avi/avi_values.yml
  #
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi ctrl configured" "${log_file}" "${slack_webhook}" "${google_webhook}"
  touch ${resultFile}
fi
exit
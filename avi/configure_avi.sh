#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/load_govc_env_with_cluster.sh
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
exit
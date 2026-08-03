#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
#
# VSAN health alarm suppression // required for tanzu
#
sed -e "s/\${vsphere_username}/${vsphere_nested_username}/" \
    -e "s/\${ssoDomain}/${ssoDomain}/" \
    -e "s/\${vsphere_password}/${generic_password}/" \
    -e "s/\${vsphere_server}/${vcsa_fqdn}/" \
    -e "s@\${dc}@${vcsa_mgmt_dc}@" \
    -e "s/\${cluster}/${vcsa_mgmt_cluster}/" /home/ubuntu/templates/silence_vsan_expect_script.sh.template | tee /home/ubuntu/vcenter/silence_vsan_expect_script.sh
#
chmod u+x /home/ubuntu/vcenter/silence_vsan_expect_script.sh
/home/ubuntu/vcenter/silence_vsan_expect_script.sh
#
#
#
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch ${resultFile}

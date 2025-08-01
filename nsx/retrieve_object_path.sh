#!/bin/bash
#
source /home/ubuntu/nsx/nsx_api.sh
#
nsx_nested_ip=${1}
nsx_password=${2}
nsx_api_endpoint=${3}
object_name=${4}
json_output_file=${5}
json_key=${6}
#
cookies_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_cookie.txt"
headers_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_header.txt"
rm -f ${cookies_file} ${headers_file}
/bin/bash /home/ubuntu/nsx/create_nsx_api_session.sh admin ${nsx_password} ${nsx_nested_ip} ${cookies_file} ${headers_file}
#
nsx_api 2 2 "GET" ${cookies_file} ${headers_file} "" ${nsx_nested_ip} "${nsx_api_endpoint}"
result=$(echo ${response_body} | jq -c -r --arg arg "${object_name}" '.results[] | select(.display_name == $arg) | .path')
echo "   +++ testing if variable result is not empty" ; if [ -z "${result}" ] ; then exit 255 ; fi
echo '{"'${json_key}'":"'${result}'"}' | tee ${json_output_file}
rm -f ${cookies_file} ${headers_file}
#!/bin/bash
#
source /home/ubuntu/nsx/nsx_api.sh
#
nsx_nested_ip=${1}
nsx_password=${2}
nsx_api_endpoint=${3}
json_output_file=${4}
#
cookies_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_cookie.txt"
headers_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_header.txt"
rm -f ${cookies_file} ${headers_file}
/bin/bash /home/ubuntu/nsx/create_nsx_api_session.sh admin ${nsx_password} ${nsx_nested_ip} ${cookies_file} ${headers_file}
#
nsx_api 2 2 "GET" ${cookies_file} ${headers_file} "" ${nsx_nested_ip} "${nsx_api_endpoint}"
result=$(echo $response_body | jq -c -r '.')
if [ -z "$result" ] ; then echo "result is empty, exiting..." ; exit 255 ; fi
echo ${result} | jq -c -r '.' > "${json_output_file}"
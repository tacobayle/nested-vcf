#!/bin/bash
#
source /home/ubuntu/nsx/nsx_api.sh
#
nsx_nested_ip=${1}
nsx_password=${2}
api_endpoint=${3}
http_method=${4}
json_data=${5}
#
cookies_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_cookie.txt"
headers_file="/home/ubuntu/nsx/nsx_$(basename $0 | cut -d"." -f1)_header.txt"
rm -f ${cookies_file} ${headers_file}
/bin/bash /home/ubuntu/nsx/create_nsx_api_session.sh admin ${nsx_password} ${nsx_nested_ip} ${cookies_file} ${headers_file}
nsx_api 2 2 "${http_method}" ${cookies_file} ${headers_file} "${json_data}" ${nsx_nested_ip} "${api_endpoint}"
echo ${response_body} | jq -c -r '.' > /home/ubuntu/nsx/response_body.json
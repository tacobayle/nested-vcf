#!/bin/bash
#
# $1 is the username
# $2 is the password
# $3 is the NSX Manager IP
# $4 is the cookie file name
# $5 is the hearders file name
#
rm -f $4 $5
retry=6
pause=10
attempt=0
while true ; do
  echo "Creating NSX API session..."
  response=$(curl https://$3/api/session/create \
                  -k \
                  -s \
                  --write-out "\n%{http_code}" \
                  -c $4 \
                  -D $5 \
                  -X POST \
                  -d 'j_username='$1'&j_password='$2'')
  http_code=$(tail -n1 <<< "$response")
  content=$(sed '$ d' <<< "$response")
  if [[ $http_code == 200 ]] ; then
    #echo "  Created NSX API session successfully: cookie file is $4 and header file is: $5"
    break
  fi
  if [ $attempt -eq $retry ]; then
    echo "  FAILED to create NSX API session failed, http_response_code: $http_code"
    exit 255
  fi
  sleep $pause
  ((attempt++))
done
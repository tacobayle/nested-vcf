ip_prefix_by_netmask () {
  # $1 netmask
  # $2 indentation message
  error_prefix=1
  if [[ $1 == "255.255.255.255" ]] ; then echo "32" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.254" ]] ; then echo "31" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.252" ]] ; then echo "30" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.248" ]] ; then echo "29" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.240" ]] ; then echo "28" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.224" ]] ; then echo "27" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.192" ]] ; then echo "26" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.128" ]] ; then echo "25" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.255.0" ]] ; then echo "24" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.254.0" ]] ; then echo "23" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.252.0" ]] ; then echo "22" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.248.0" ]] ; then echo "21" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.240.0" ]] ; then echo "20" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.224.0" ]] ; then echo "19" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.192.0" ]] ; then echo "18" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.128.0" ]] ; then echo "17" ; error_prefix=0 ; fi
  if [[ $1 == "255.255.0.0" ]] ; then echo "16" ; error_prefix=0 ; fi
  if [[ $1 == "255.254.0.0" ]] ; then echo "15" ; error_prefix=0 ; fi
  if [[ $1 == "255.252.0.0" ]] ; then echo "14" ; error_prefix=0 ; fi
  if [[ $1 == "255.248.0.0" ]] ; then echo "13" ; error_prefix=0 ; fi
  if [[ $1 == "255.240.0.0" ]] ; then echo "12" ; error_prefix=0 ; fi
  if [[ $1 == "255.224.0.0" ]] ; then echo "11" ; error_prefix=0 ; fi
  if [[ $1 == "255.192.0.0" ]] ; then echo "10" ; error_prefix=0 ; fi
  if [[ $1 == "255.128.0.0" ]] ; then echo "9" ; error_prefix=0 ; fi
  if [[ $1 == "255.0.0.0" ]] ; then echo "8" ; error_prefix=0 ; fi
  if [[ $1 == "254.0.0.0" ]] ; then echo "7" ; error_prefix=0 ; fi
  if [[ $1 == "252.0.0.0" ]] ; then echo "6" ; error_prefix=0 ; fi
  if [[ $1 == "248.0.0.0" ]] ; then echo "5" ; error_prefix=0 ; fi
  if [[ $1 == "240.0.0.0" ]] ; then echo "4" ; error_prefix=0 ; fi
  if [[ $1 == "224.0.0.0" ]] ; then echo "3" ; error_prefix=0 ; fi
  if [[ $1 == "192.0.0.0" ]] ; then echo "2" ; error_prefix=0 ; fi
  if [[ $1 == "128.0.0.0" ]] ; then echo "1" ; error_prefix=0 ; fi
  if [[ error_prefix -eq 1 ]] ; then echo "$2+++ $1 does not seem to be a proper netmask" ; fi
}

ip_netmask_by_prefix () {
  # $1 prefix
  # $2 indentation message
  error_prefix=1
  if [[ $1 == "32" ]] ; then echo "255.255.255.255" ; error_prefix=0 ; fi
  if [[ $1 == "31" ]] ; then echo "255.255.255.254" ; error_prefix=0 ; fi
  if [[ $1 == "30" ]] ; then echo "255.255.255.252" ; error_prefix=0 ; fi
  if [[ $1 == "29" ]] ; then echo "255.255.255.248" ; error_prefix=0 ; fi
  if [[ $1 == "28" ]] ; then echo "255.255.255.240" ; error_prefix=0 ; fi
  if [[ $1 == "27" ]] ; then echo "255.255.255.224" ; error_prefix=0 ; fi
  if [[ $1 == "26" ]] ; then echo "255.255.255.192" ; error_prefix=0 ; fi
  if [[ $1 == "25" ]] ; then echo "255.255.255.128" ; error_prefix=0 ; fi
  if [[ $1 == "24" ]] ; then echo "255.255.255.0"   ; error_prefix=0 ; fi
  if [[ $1 == "23" ]] ; then echo "255.255.254.0"   ; error_prefix=0 ; fi
  if [[ $1 == "22" ]] ; then echo "255.255.252.0"   ; error_prefix=0 ; fi
  if [[ $1 == "21" ]] ; then echo "255.255.248.0"   ; error_prefix=0 ; fi
  if [[ $1 == "20" ]] ; then echo "255.255.240.0"   ; error_prefix=0 ; fi
  if [[ $1 == "19" ]] ; then echo "255.255.224.0"   ; error_prefix=0 ; fi
  if [[ $1 == "18" ]] ; then echo "255.255.192.0"   ; error_prefix=0 ; fi
  if [[ $1 == "17" ]] ; then echo "255.255.128.0"   ; error_prefix=0 ; fi
  if [[ $1 == "16" ]] ; then echo "255.255.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "15" ]] ; then echo "255.254.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "14" ]] ; then echo "255.252.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "13" ]] ; then echo "255.248.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "12" ]] ; then echo "255.240.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "11" ]] ; then echo "255.224.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "10" ]] ; then echo "255.192.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "9" ]] ; then echo  "255.128.0.0"     ; error_prefix=0 ; fi
  if [[ $1 == "8" ]] ; then echo  "255.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "7" ]] ; then echo  "254.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "6" ]] ; then echo  "252.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "5" ]] ; then echo  "248.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "4" ]] ; then echo  "240.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "3" ]] ; then echo  "224.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "2" ]] ; then echo  "192.0.0.0"       ; error_prefix=0 ; fi
  if [[ $1 == "1" ]] ; then echo  "128.0.0.0"       ; error_prefix=0 ; fi
  if [[ error_prefix -eq 1 ]] ; then echo "$2+++ $1 does not seem to be a proper netmask" ; fi
}

nextip(){
    IFS=$' \t\n'
    IP=$1
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
    IFS=$'\n'
}

amount_of_ip_by_prefix () {
  # $1 prefix
  if [[ $1 == "32" ]] ; then echo "1" ; fi
  if [[ $1 == "31" ]] ; then echo "2" ; fi
  if [[ $1 == "30" ]] ; then echo "2" ; fi
  if [[ $1 == "29" ]] ; then echo "6" ; fi
  if [[ $1 == "28" ]] ; then echo "14" ; fi
  if [[ $1 == "27" ]] ; then echo "30" ; fi
  if [[ $1 == "26" ]] ; then echo "62" ; fi
  if [[ $1 == "25" ]] ; then echo "126" ; fi
  if [[ $1 == "24" ]] ; then echo "254" ; fi
  if [[ $1 == "23" ]] ; then echo "510" ; fi
  if [[ $1 == "22" ]] ; then echo "1022" ; fi
  if [[ $1 == "21" ]] ; then echo "2046" ; fi
  if [[ $1 == "20" ]] ; then echo "4094" ; fi
  if [[ $1 == "19" ]] ; then echo "8190" ; fi
  if [[ $1 == "18" ]] ; then echo "16382" ; fi
  if [[ $1 == "17" ]] ; then echo "32766" ; fi
  if [[ $1 == "16" ]] ; then echo "65534" ; fi
  if [[ $1 == "15" ]] ; then echo "131070" ; fi
  if [[ $1 == "14" ]] ; then echo "262142" ; fi
  if [[ $1 == "13" ]] ; then echo "524286" ; fi
  if [[ $1 == "12" ]] ; then echo "1048574" ; fi
  if [[ $1 == "11" ]] ; then echo "2097150" ; fi
  if [[ $1 == "10" ]] ; then echo "4194302" ; fi
  if [[ $1 == "9" ]] ; then echo  "8388606" ; fi
  if [[ $1 == "8" ]] ; then echo  "16777214" ; fi
  if [[ $1 == "7" ]] ; then echo  "33554430" ; fi
  if [[ $1 == "6" ]] ; then echo  "67108862" ; fi
  if [[ $1 == "5" ]] ; then echo  "137217726" ; fi
  if [[ $1 == "4" ]] ; then echo  "268435454" ; fi
  if [[ $1 == "3" ]] ; then echo  "536870910" ; fi
  if [[ $1 == "2" ]] ; then echo  "1073741822" ; fi
  if [[ $1 == "1" ]] ; then echo  "2147483646" ; fi
}

remove_last_octet() {
  local ip="$1"
  local parts=(${ip//./ })

  if [[ ${#parts[@]} -ne 4 ]]; then
    echo "Invalid IP address: $ip"
    return 1
  fi

  # Remove the last element from the array
  unset parts[3]

  # Join the remaining elements with dots
  ip="${parts[*]}"
  ip="${ip// /.}"
  echo "$ip"
}
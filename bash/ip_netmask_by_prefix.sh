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

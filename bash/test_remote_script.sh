test_remote_script() {
  local retry=60
  local pause=10
  local attempt=1
  local ip_gw="${1}"
  local script_file="${2}"
  while true ; do
      echo "attempt ${attempt} to verify ${script_file} have been done properly"
      ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" "test -f ${script_file%.*}.done" 2>/dev/null
      if [[ $? -eq 0 ]]; then
        echo "${script_file} has been executed until the end"
        process_id=$(ps -ef | grep "${script_file}" | grep -v grep | awk '{print $1}')
        if [[ -z "${process_id}" ]]; then echo "process associated with ${script_file} is already terminated properly"; else kill -9 ${process_id} ; fi
        break
      else
        echo "${script_file} has not executed until the end"
      fi
      ((attempt++))
      if [ $attempt -eq $retry ]; then
        echo "${script_file} has not executed until the end after ${attempt} attempts of ${pause} seconds"
        exit
      fi
      sleep ${pause}
    done
}
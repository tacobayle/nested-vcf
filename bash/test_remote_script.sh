test_remote_script() {
  local log_file=${1}
  local retry=${2}
  local pause=${3}
  local ip_gw="${4}"
  local script_file="${5}"
  local attempt=1
  while true ; do
      echo "attempt ${attempt} to verify ${script_file} have been done properly" >> ${log_file}
      ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" "test -f ${script_file%.*}.done" < /dev/null 2>/dev/null
      if [[ $? -eq 0 ]]; then
        echo "${script_file} has been executed until the end" >> ${log_file}
#        process_id=$(ps -ef | grep "${script_file}" | grep -v grep | awk '{print $1}')
#        if [[ -z "${process_id}" ]]; then echo "process associated with ${script_file} is already terminated properly" >> ${log_file} ; else kill -9 ${process_id} ; fi
        return 0
      else
        echo "${script_file} has not executed until the end" >> ${log_file}
      fi
      ((attempt++))
      if [ $attempt -eq $retry ]; then
        echo "${script_file} has not executed until the end after ${attempt} attempts of ${pause} seconds" >> ${log_file}
        return 100
      fi
      sleep ${pause}
    done
}
log_message() {
  local message="${1}"
  local log_file="${2}"
  local slack_url="${3}"
  local google_url="${4}"
  if [[ -z "${message}" ]]; then
    echo "Error: message is missing."
    return 1
  fi
  if [[ -f "${log_file}" ]]; then echo "${message}" >> ${log_file} ; else echo "${message}"; fi
  # slack
  if [ -z "${slack_url}" ] ; then : ; else curl -X POST -H "Content-type: application/json" -d "{\"text\":\"${message}\"}" "${slack_url}" > /dev/null 2>&1; fi
  # google chat
  if [[ -z "${google_url}" ]]; then : ; else curl -X POST -H "Content-Type: application/json" -d "{\"text\":\"${message}\"}" "${google_url}" > /dev/null 2>&1; fi
}
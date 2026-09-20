#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcenter/vcenter_api.sh
source /home/ubuntu/bash/download_file.sh
#
#
#
if [[ ${vcf_version_two_digit} == "9.0" || ${vcf_version_two_digit} == "9.1" ]]; then
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 6 10 "GET" $token '' ${vcsa_fqdn} "rest/vcenter/datastore"
  datastore_id=$(echo $response_body | jq -c -r --arg arg "${basename_sddc}-vsan" '.value[] | select(.name == $arg) | .datastore')
  ValidCmThumbPrint=$(openssl s_client -connect $(echo ${content_library_subscription_url}  | cut -d"/" -f3):443 < /dev/null 2>/dev/null | openssl x509 -fingerprint -noout -in /dev/stdin | awk -F'Fingerprint=' '{print $2}')
  json_data='
  {
    "storage_backings":
    [
      {
        "datastore_id":"'${datastore_id}'",
        "type":"DATASTORE"
      }
    ],
    "type": "SUBSCRIBED",
    "version":"2",
    "subscription_info":
      {
        "authentication_method":"NONE",
        "ssl_thumbprint":"'${ValidCmThumbPrint}'",
        "automatic_sync_enabled": "true",
        "subscription_url": "'${content_library_subscription_url}'",
        "on_demand": "true"
      },
    "name": "content_library_supervisor"
  }'
  vcenter_api 3 3 "POST" $token "${json_data}" ${vcsa_fqdn} "api/content/subscribed-library"
  content_library_id=$(echo $response_body | tr -d '"')
  #
  # Retrieve cluster id
  #
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/cluster"
  cluster_id=$(echo $response_body | jq -r --arg cluster "${basename_sddc}-cluster" '.[] | select(.name == $cluster).cluster')
  #
  # Retrieve storage policy
  #
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/storage/policies"
  storage_policy_id=$(echo $response_body | jq -r --arg policy "${supervisor_cluster_storage_policy_ref}" '.[] | select(.name == $policy) | .policy')
  #
  # Retrieve network id
  #
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/network"
  network_supervisor_management=$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).display_name')
  network_id=$(echo $response_body | jq -r --arg pg "${network_supervisor_management}" '.[] | select(.name == $pg).network')
  #
  # Supervisor cluster creation
  #
  json_data='{
      "control_plane": {
          "count": 1,
          "login_banner": "'${supervisor_cluster_name}'-banner",
          "network": {
              "backing": {
                  "backing": "NETWORK_SEGMENT",
                  "network_segment": {
                      "networks": [ "'${network_id}'" ]
                  }
              },
              "ip_management": {
                  "dhcp_enabled": false,
                  "gateway_address": "'$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).gateway_address')'",
                  "ip_assignments": [ {
                      "assignee": "NODE",
                      "ranges": [ {
                          "address": "'$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_starting_ip')'",
                          "count": '$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_count')'
                      } ]
                  } ]
              },
              "network": "managementnetwork0",
              "proxy": {
                  "proxy_settings_source": "VC_INHERITED"
              },
              "services": {
                  "dns": {
                      "search_domains": [ "'${domain}'" ],
                      "servers": [ "'${ip_gw}'" ]
                  },
                  "ntp": {
                      "servers": [ "'${ip_gw}'" ]
                  }
              }
          },
          "size": "'${supervisor_cluster_size}'",
          "storage_policy": "'${storage_policy_id}'"
      },
      "name": "'${supervisor_cluster_name}'",
      "workloads": {
          "edge": {
              "provider": "NSX_VPC"
          },
          "network": {
              "ip_management": {
                  "dhcp_enabled": false,
                  "gateway_address": "",
                  "ip_assignments": [ {
                      "assignee": "SERVICE",
                      "ranges": [ {
                          "address": "'${supervisor_cluster_service_address}'",
                          "count": '${supervisor_cluster_service_address_count}'
                      } ]
                  } ]
              },
              "network": "workloadnetwork0",
              "network_type": "NSX_VPC",
              "nsx_vpc": {
                  "default_private_cidrs": [ {
                      "address": "'${supervisor_cluster_vpc_private_cidr_address}'",
                      "prefix": '${supervisor_cluster_vpc_private_cidr_prefix}'
                  } ],
                  "nsx_project": "/orgs/default/projects/'${supervisor_cluster_project_ref}'",
                  "vpc_connectivity_profile": "/orgs/default/projects/'${supervisor_cluster_project_ref}'/vpc-connectivity-profiles/'${supervisor_cluster_vpc_profile}'"
              },
              "services": {
                  "dns": {
                      "search_domains": [ "'${domain}'" ],
                      "servers": [ "'${ip_gw}'" ]
                  },
                  "ntp": {
                      "servers": [ "'${ip_gw}'" ]
                  }
              }
          },
          "storage": {
              "ephemeral_storage_policy": "'${storage_policy_id}'",
              "image_storage_policy": "'${storage_policy_id}'"
          }
      }
  }'
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "POST" $token "${json_data}" ${vcsa_fqdn} "api/vcenter/namespace-management/supervisors/${cluster_id}?action=enable_on_compute_cluster"
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, waiting 600 seconds" "${log_file}" "" ""
  sleep 600
  #
  #
  #
  retry_tanzu_supervisor=121
  pause_tanzu_supervisor=60
  attempt_tanzu_supervisor=1
  while true ; do
    token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
    vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/namespace-management/clusters"
    if [[ $(echo $response_body | jq -c -r .[0].config_status) == "RUNNING" && $(echo $response_body | jq -c -r .[0].kubernetes_status) == "READY" ]]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, supervisor config_status is $(echo $response_body | jq -c -r .[0].config_status) and kubernetes_status is $(echo $response_body | jq -c -r .[0].kubernetes_status) after ${attempt_tanzu_supervisor} attempts of ${pause_tanzu_supervisor} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      break 2
    fi
    ((attempt_tanzu_supervisor++))
    if [ ${attempt_tanzu_supervisor} -eq ${retry_tanzu_supervisor} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Unable to get supervisor cluster config_status RUNNING and kubernetes_status READY after ${attempt_tanzu_supervisor} attempts of ${pause_tanzu_supervisor} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit
    fi
    sleep ${pause_tanzu_supervisor}
  done
  #
  # Retrieve API server cluster endpoint
  #
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "GET" $token '' "${vcsa_fqdn}" "api/vcenter/namespace-management/clusters"
  cluster_id=$(echo $response_body | jq -c -r .[0].cluster)
  json_output_file="/home/ubuntu/vcenter/api_server_cluster_endpoint.json"
  vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/namespace-management/clusters/${cluster_id}"
  api_server_cluster_endpoint=$(echo $response_body | jq -c -r .api_server_cluster_endpoint)
  if [ -z "${api_server_cluster_endpoint}" ] ; then exit 255 ; fi
  echo '{"api_server_cluster_endpoint": "'${api_server_cluster_endpoint}'"}' | tee ${json_output_file}
  #
  # Init k8s config
  #
  export VCF_CLI_VSPHERE_PASSWORD=''${generic_password}''
  vcf context create ${supervisor_cluster_name} --auth-type basic --username administrator@${ssoDomain} --endpoint=${api_server_cluster_endpoint} --insecure-skip-tls-verify
  sed -e "s/\${generic_password}/${generic_password}/" \
      -e "s/\${supervisor_cluster_name}/${supervisor_cluster_name}/" /home/ubuntu/templates/auth_supervisor_custer.sh.template | tee /home/ubuntu/supervisor/auth_supervisor_custer.sh > /dev/null
  chmod u+x /home/ubuntu/supervisor/auth_supervisor_custer.sh
  if [[ ${vcf_version_two_digit} == "9.0" ]]; then
    sed -e "s/\${generic_password}/${generic_password}/" \
        -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
        -e "s/\${ssoDomain}/${ssoDomain}/" /home/ubuntu/templates/auth_vks_context_9.0.sh.template | tee /home/ubuntu/supervisor/auth_vks_context.sh > /dev/null
    chmod u+x /home/ubuntu/supervisor/auth_vks_context.sh
  fi
  if [[ ${vcf_version_two_digit} == "9.1" ]]; then
    sed -e "s/\${generic_password}/${generic_password}/" \
        -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
        -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" /home/ubuntu/templates/vcfa_select_vks_cluster.sh.template | tee /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh > /dev/null
    chmod u+x /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh
    sed -e "s/\${generic_password}/${generic_password}/" \
        -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" /home/ubuntu/templates/vcfa_select_ns.sh.template | tee /home/ubuntu/supervisor/vcfa_select_ns.sh > /dev/null
    chmod u+x /home/ubuntu/supervisor/vcfa_select_ns.sh
    sed -e "s/\${generic_password}/${generic_password}/" \
        -e "s/\${ssoDomain}/${ssoDomain}/" \
        -e "s/\${vsphere_nested_username}/${vsphere_nested_username}/" \
        -e "s/\${vcsa_fqdn}/${vcsa_fqdn}/" /home/ubuntu/templates/enable_supervisor_service.sh.template | tee /home/ubuntu/supervisor/enable_supervisor_service.sh > /dev/null
    chmod u+x /home/ubuntu/supervisor/enable_supervisor_service.sh
    #
    # download yaml supervisor services
    #
    source /home/ubuntu/avi/avi_api.sh
    while read item
    do
      svc_type="$(echo ${item} | jq -c -r '.type // "carvel-yaml"')"
      url="$(echo ${item} | jq -c -r '.url')"
      service_file="/home/ubuntu/supervisor/$(basename ${url})"
      download_file_from_url_to_location "${url}" "${service_file}" "$(basename ${url})"

      if [ "${svc_type}" == "harbor" ]; then
        #
        # Harbor is already globally registered/ACTIVATED in a stock VCF
        # 9.1 environment, so no real Package/PackageMetadata registration
        # is needed - but url still names the real upstream registration
        # manifest (downloaded like everything else here) so
        # enable_supervisor_service.sh's own "already registered, skip"
        # check runs against real content, keeping this portable to a VCF
        # environment where Harbor isn't pre-registered. Ported from the
        # epc-vapp project's own equivalent logic (ISO-delivered there
        # instead of downloaded, everything else identical) - see that
        # project's vcf_bootstrap.sh for the full live-tested rationale
        # (carvel_spec vs custom_spec, enableNginxLoadBalancer,
        # tlsSecretLabels, the DNS/image-preload steps below).
        #
        values_template_url="$(echo ${item} | jq -c -r '.values_template_url // empty')"
        if [ -z "${values_template_url}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: harbor supervisor_services entry needs values_template_url, skipping: ${item}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi
        values_template_file="/home/ubuntu/supervisor/$(basename ${values_template_url})"
        download_file_from_url_to_location "${values_template_url}" "${values_template_file}" "$(basename ${values_template_url})"

        # Not user-configurable - always the same well-known FQDN pattern
        # every other Avi-fronted hostname in this deployment already uses
        # (see configure_avi.sh's own avi_dns_domains_json), under the
        # Avi-delegated app.vcf9.lab-style zone so dns-vs can serve it
        # once registered below.
        harbor_hostname="harbor.${avi_subdomain}.${domain}"
        # NOT supervisor_cluster_storage_policy_ref directly - that's the
        # vCenter storage POLICY's own display name (e.g. "vSAN Default
        # Storage Policy", spaces and all - confirmed live), not a valid
        # Kubernetes object name. The actual StorageClass vSphere CSI
        # creates for this cluster follows this project's own existing
        # "${basename_sddc}-cluster"-based cluster_name convention
        # (bash/variables.sh's own cluster_name, already used elsewhere in
        # this script) - confirmed live against a real Supervisor cluster
        # ("sddc01-cluster-vsan-storage-policy" exists, "vSAN Default
        # Storage Policy" does not - PVCs referencing the latter would
        # never bind).
        harbor_storage_class="${cluster_name}-vsan-storage-policy"
        harbor_admin_password="${generic_password}"
        harbor_secret_key=$(echo -n "${generic_password}harbor-secretkey" | md5sum | cut -c1-16)
        harbor_database_password=$(echo -n "${generic_password}harbor-database" | md5sum | cut -c1-16)
        harbor_core_secret=$(echo -n "${generic_password}harbor-core" | md5sum | cut -c1-16)
        harbor_core_xsrf_key_raw=$(echo -n "${generic_password}harbor-xsrf" | md5sum)
        harbor_core_xsrf_key="${harbor_core_xsrf_key_raw}${harbor_core_xsrf_key_raw}"
        harbor_core_xsrf_key="${harbor_core_xsrf_key:0:32}"
        harbor_jobservice_secret=$(echo -n "${generic_password}harbor-jobservice" | md5sum | cut -c1-16)
        harbor_registry_secret=$(echo -n "${generic_password}harbor-registry" | md5sum | cut -c1-16)

        # Python literal string replacement, not sed - harbor_admin_password
        # is this deployment's own generic_password verbatim, which may
        # contain almost any character (confirmed live in epc-vapp: this
        # environment's own password contains "@", which broke a sed
        # s@...@...@ delimiter outright). Values passed via environment
        # variables, not embedded in the Python source itself, so no
        # shell-quoting/escaping concern regardless of content.
        rendered_values_file="/tmp/harbor-values-rendered.yml"
        HARBOR_HOSTNAME="${harbor_hostname}" \
        HARBOR_ADMIN_PASSWORD="${harbor_admin_password}" \
        HARBOR_SECRET_KEY="${harbor_secret_key}" \
        HARBOR_DATABASE_PASSWORD="${harbor_database_password}" \
        HARBOR_CORE_SECRET="${harbor_core_secret}" \
        HARBOR_CORE_XSRF_KEY="${harbor_core_xsrf_key}" \
        HARBOR_JOBSERVICE_SECRET="${harbor_jobservice_secret}" \
        HARBOR_REGISTRY_SECRET="${harbor_registry_secret}" \
        HARBOR_STORAGE_CLASS="${harbor_storage_class}" \
        python3 -c "
import os
text = open('${values_template_file}').read()
for placeholder, env_var in [
    ('\${harbor_hostname}', 'HARBOR_HOSTNAME'),
    ('\${harbor_admin_password}', 'HARBOR_ADMIN_PASSWORD'),
    ('\${harbor_secret_key}', 'HARBOR_SECRET_KEY'),
    ('\${harbor_database_password}', 'HARBOR_DATABASE_PASSWORD'),
    ('\${harbor_core_secret}', 'HARBOR_CORE_SECRET'),
    ('\${harbor_core_xsrf_key}', 'HARBOR_CORE_XSRF_KEY'),
    ('\${harbor_jobservice_secret}', 'HARBOR_JOBSERVICE_SECRET'),
    ('\${harbor_registry_secret}', 'HARBOR_REGISTRY_SECRET'),
    ('\${harbor_storage_class}', 'HARBOR_STORAGE_CLASS'),
]:
    text = text.replace(placeholder, os.environ[env_var])
open('${rendered_values_file}', 'w').write(text)
"

        /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}" "${rendered_values_file}"
        rm -f "${rendered_values_file}"

        # Register harbor_hostname with Avi now that harbor-nginx's own
        # LoadBalancer Service has a real VIP - app.vcf9.lab (or whatever
        # zone harbor_hostname falls under) is delegated to Avi's own
        # dns-vs Virtual Service (the dns-avi IPAMDNSProviderProfile's
        # dns_service_domain lists it - see configure_avi.sh), and
        # arbitrary FQDN->IP static mappings not tied to an Avi-managed
        # Ingress/Service belong on dns-vs's own static_dns_records field
        # directly - not per-VS dns_info, which only applies to VSes Avi
        # itself created from an Ingress/Service hostname. Ported from
        # epc-vapp's vcf_bootstrap.sh, confirmed live there.
        kubectl config use-context "${supervisor_cluster_name}"
        harbor_namespace="$(kubectl get namespaces -o name | grep -o 'svc-harbor-[a-z0-9]*' | head -1)"
        if [ -z "${harbor_namespace}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: harbor namespace (svc-harbor-*) not found - skipping DNS registration for ${harbor_hostname}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          harbor_ip=""
          for attempt_harbor_ip in $(seq 1 12); do
            harbor_ip="$(kubectl get svc -n "${harbor_namespace}" harbor-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
            [ -n "${harbor_ip}" ] && break
            sleep 10
          done
          if [ -z "${harbor_ip}" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: harbor-nginx Service in ${harbor_namespace} has no LoadBalancer IP after waiting - skipping DNS registration for ${harbor_hostname}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          else
            date_index=$(date '+%Y%m%d%H%M%S')
            avi_cookie_file="/tmp/harbor_dns_${date_index}_cookie.txt"
            curl_login=$(curl -s -k -X POST -H "Content-Type: application/json" \
                                            -d "{\"username\": \"admin\", \"password\": \"${generic_password}\"}" \
                                            -c ${avi_cookie_file} https://${ip_avi}/login)
            csrftoken=$(cat ${avi_cookie_file} | grep csrftoken | awk '{print $7}')
            avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${ip_avi}" "api/virtualservice?name=dns-vs"
            dns_vs_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
            avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${ip_avi}" "api/virtualservice/${dns_vs_uuid}"
            static_dns_records=$(echo ${response_body} | jq -c --arg fqdn "${harbor_hostname}" --arg ip "${harbor_ip}" \
              '[.static_dns_records[]? | select(.fqdn != [$fqdn])] + [{type: "DNS_RECORD_A", algorithm: "DNS_RECORD_RESPONSE_ROUND_ROBIN", fqdn: [$fqdn], ip_address: [{ip_address: {addr: $ip, type: "V4"}}]}]')
            avi_api 2 2 "PATCH" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "$(jq -n --argjson records "${static_dns_records}" '{replace: {static_dns_records: $records}}')" "${ip_avi}" "api/virtualservice/${dns_vs_uuid}"
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: registered DNS record ${harbor_hostname} -> ${harbor_ip} on Avi's dns-vs" "${log_file}" "" ""
            rm -f "${avi_cookie_file}"

            # Optional image preload (this entry's own 'images', each a
            # bare filename downloaded from the SAME base URL as this
            # entry's own 'url' - unlike epc-vapp's ISO-delivered
            # tarballs, sddc has no ISO mechanism, so every file here is
            # fetched directly, same as the registration manifest/values
            # template above).
            harbor_images_json="$(echo ${item} | jq -c '.images // []')"
            if [ "${harbor_images_json}" != "[]" ]; then
              if ! command -v skopeo >/dev/null 2>&1; then
                sudo apt-get install -y skopeo || log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: apt-get install skopeo failed, skipping harbor image preload" "${log_file}" "${slack_webhook}" "${google_webhook}"
              fi
              if command -v skopeo >/dev/null 2>&1; then
                harbor_registry_project="registry"
                base_url="$(dirname "${url}")"
                project_check_code=$(curl -sk -o /dev/null -w "%{http_code}" -u "admin:${harbor_admin_password}" \
                  "https://${harbor_ip}/api/v2.0/projects/${harbor_registry_project}")
                if [ "${project_check_code}" == "404" ]; then
                  curl -sk -u "admin:${harbor_admin_password}" -X POST "https://${harbor_ip}/api/v2.0/projects" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n --arg name "${harbor_registry_project}" '{project_name: $name, public: true}')" >/dev/null
                fi
                echo "${harbor_images_json}" | jq -c -r .[] | while read -r image_file
                do
                  image_path="/home/ubuntu/supervisor/${image_file}"
                  download_file_from_url_to_location "${base_url}/${image_file}" "${image_path}" "${image_file}"
                  image_name="$(basename "${image_file}" .tar.gz)"
                  image_name="$(basename "${image_name}" .tar)"
                  if skopeo copy --dest-tls-verify=false --dest-creds "admin:${harbor_admin_password}" \
                      "oci-archive:${image_path}" "docker://${harbor_ip}/${harbor_registry_project}/${image_name}:latest"; then
                    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: pushed ${image_file} to Harbor as ${harbor_registry_project}/${image_name}:latest (pull via ${harbor_hostname}/${harbor_registry_project}/${image_name}:latest)" "${log_file}" "" ""
                  else
                    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to push ${image_file} to Harbor" "${log_file}" "${slack_webhook}" "${google_webhook}"
                  fi
                done
              fi
            fi
          fi
        fi
        continue
      fi

      # carvel-yaml (default) - existing behavior, unchanged.
      /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}"
    done < <(echo "${supervisor_services}" | jq -c -r .[])
  fi
fi
#
#
#
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch ${resultFile}
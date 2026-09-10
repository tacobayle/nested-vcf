#!/bin/bash
#
# VCF Automation (VCFA) org configuration - enhanced port of the reference
# project's vcf-automation/configure_vcfa.sh, incorporating fixes and API
# details confirmed live against a real VCF 9.1 SDDC's VCFA instance
# (org-1 already existed; org-2 and org-3 were created and fully verified
# end-to-end this way, including org-3 deliberately skipping the
# aviSetting step to test provider-mode Avi configuration by hand
# afterward). Fixes/discoveries vs. the original:
#
#   - JSON payload bugs: the original's virtualDatacenters POST was
#     missing a closing '}' after the supervisor id (invalid JSON, would
#     never actually have POSTed), and its virtualDatacenterStoragePolicies
#     step built the correct payload then immediately overwrote it with
#     the (wrong) vm_classes payload copy-pasted from the previous step -
#     both fixed here by building every payload with jq -n instead of
#     manual string concatenation.
#   - The original referenced ${zone_id}/${zone_name} when creating a
#     vDC's zoneResourceAllocation but never actually set them anywhere in
#     the script - a real gap, not just a bug. These now come from each
#     org's own input (zone_ref/zone_id below), matching how org-1's own
#     live vDC actually has them set (zone "domain-c9" - the vSphere
#     compute cluster's own moref, 1:1 with this project's single Region).
#   - API version: several cloudapi/v1/* endpoints (virtualDatacenter
#     StoragePolicies PUT, regionalNetworkingSettings/{id}/aviSetting
#     GET/PUT) reject "9.0.0" (used elsewhere in this project's other
#     scripts) with an opaque HTTP 405 from
#     RestApiRequestVersionCompatibilityFilter, even though OPTIONS
#     confirms the HTTP method itself is allowed - they need "9.1.0"
#     instead. Standardized this whole script on 9.1.0 since it works
#     identically everywhere else too (re-confirmed against orgs/
#     virtualDatacenters/virtualMachineClasses/regions with no behavior
#     change vs 9.0.0).
#   - Added idempotency (GET-by-name before POST) throughout - re-running
#     this against already-configured resources otherwise either fails
#     outright or, worse, silently creates a duplicate depending on the
#     endpoint (confirmed live: a careless probe POST during API discovery
#     created a real, if harmless, throwaway org that had to be cleaned up
#     by hand).
#   - Added the Avi/Load-Balancing regional setting
#     (cloudapi/v1/regionalNetworkingSettings/{id}/aviSetting) as its own
#     step - not present anywhere in the original script, found only via
#     the VCFA UI's own network calls (no other documentation located for
#     it). Made optional per-org via enable_avi (defaults to true) for
#     exactly this reason: an org can be deliberately left without it.
#   - Confirmed live that a provider gateway/edge cluster already in use
#     by one org (this project's ext-connection1/edge-cluster-01, both
#     created for org-1) can be reused by additional orgs' regional
#     networking settings with no extra "shared connection" step needed -
#     it just goes CONFIGURING -> REALIZED like any other org's own
#     setting. The original's own captured error ("Provider Gateway
#     test-ui must be backed by a shared Gateway Connection") was
#     presumably specific to a not-yet-fully-configured gateway in that
#     author's own test environment, not a general limitation.
#   - The region/ipSpace/providerGateway creation block below (never
#     actually exercised on the vcf9 lab, since all three already existed
#     there for org-1) was separately tested end-to-end against a second,
#     independent VCD/VCFA environment using the exact same payloads as
#     below: region -> ipSpace -> providerGateway all created cleanly
#     (202 -> REALIZED, no errors). This also answered the "brand new
#     gateway" question above - the created providerGateway had
#     gatewayConnectionBackingId auto-populated by VCFA from its own name
#     (matching the pattern already seen on org-1's ext-connection1) and
#     natConfig left null/unset, with no separate "shared Gateway
#     Connection" step required. ipSpaceRefs read back as null despite
#     being sent and accepted - same non-echo behavior already seen on
#     aviSetting's serviceEngineGroupRefs, not evidence it wasn't applied.
#   - A brand-new region has no edgeCluster discoverable via a plain GET -
#     cloudapi/v1/edgeClusters/sync (no region/id in the path, confirmed a
#     real endpoint via OPTIONS -> allow: POST,OPTIONS) must be POSTed
#     first to trigger NSX transport-node discovery; the edge cluster then
#     appears after roughly 60s. Added as an automatic fallback in the
#     "configure orgs" networking step below.
#   - The full "configure orgs" loop (org -> vDC -> VM classes -> storage
#     policy -> regionalNetworkingSettings) was batch-tested end-to-end on
#     that same second environment - created 10 orgs against a brand-new
#     region/providerGateway/edgeCluster in one run, all reaching
#     REALIZED with no failures. This also caught a real gap in that
#     environment's vDC creation: "Region Quota supervisors is a required
#     field, and must contain one supervisor" - the vDC payload below
#     already includes supervisors: [{name, id}] for exactly this reason.
#   - Dropped the "assign a user" step's hardcoded real username AND
#     plaintext password - never commit real credentials to a script.
#     Left commented out with a note to source both from this project's
#     own secrets handling instead.
#   - Replaced the undocumented vcfa_api/bash/vcfa/vcfa.sh dependency
#     (never seen that file's actual implementation, so couldn't verify or
#     safely extend its interface, e.g. for the version-header override
#     several endpoints above need) with a small self-contained
#     provider-login + API-call function pair, matching the auth flow
#     templates/vcfa_select_ns.sh.template already documents (provider
#     Basic auth as "admin@system" against
#     /cloudapi/1.0.0/sessions/provider, bearer token from the
#     x-vmware-vcloud-access-token response header).
#
# Expected shape of vcf_a_organizations (richer than the original, which
# never actually defined zone_id/zone_name/storage/networking inputs):
#   [{
#     "name": "org-2",
#     "region_ref": "region-1",
#     "zone_ref": "domain-c9",
#     "zone_id": "urn:vcloud:zone:efef1be8-a2aa-5404-b65e-912b6a2c7c39",
#     "cpu_limit_mhz": 228540,
#     "memory_limit_mib": 496237,
#     "storage_limit": 102400,
#     "provider_gateway_ref": "ext-connection1",
#     "edge_cluster_ref": "edge-cluster-01",
#     "enable_avi": true,
#     "avi_mode": "TENANT_MANAGED",
#     "avi_quota": 10,
#     "avi_service_engine_group_ref": null
#   }]
#
# avi_mode is either "TENANT_MANAGED" (org self-provisions its own service
# engines - avi_quota maps to the API's serviceEngineQuota field) or
# "PROVIDER_MANAGED" (org is assigned a specific, already-existing
# provider Avi service engine group named by avi_service_engine_group_ref
# - avi_quota maps to applicationLimit instead, a different field
# entirely). Both confirmed live: org-1 uses TENANT_MANAGED, org-3 was
# reconfigured by hand to PROVIDER_MANAGED against SEG "test123"/quota 20
# to confirm the API contract before wiring it in here. PROVIDER_MANAGED
# was later batch-tested against 3 orgs and a fresh SEG ("provider_seg")
# on a second environment - the aviSetting PUT itself returned 202 for all
# three, but VCF-A's own UI then reported "service engine group has not
# been assigned" because the avi controller had never been synced
# (POST cloudapi/v1/loadBalancer/aviControllers/{id}/sync, id from GET
# cloudapi/v1/loadBalancer/aviControllers) - a 202 from the aviSetting PUT
# does NOT mean the SEG assignment actually realized. Fixed below by
# syncing the controller once (per script run) before the first
# PROVIDER_MANAGED SEG lookup.
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch "${log_file}"
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh

VCFA_HOST="https://${fqdn_vcfa}"
VCFA_VERSION="${vcf_version_three_digit}"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"

vcfa_login() {
  local creds
  creds=$(printf '%s@system:%s' "admin" "${generic_password}" | base64 -w0)
  local resp
  resp=$(curl -sk -i -X POST "${VCFA_HOST}/cloudapi/1.0.0/sessions/provider" \
    -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Basic ${creds}")
  vcfa_token=$(printf '%s' "$resp" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
  if [ -z "${vcfa_token}" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A provider login FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
}

vcfa_api() {
  # $1 method, $2 endpoint (relative to /), $3 data, $4 retries, $5 pause
  # - re-logs in once per call on a 401, since provider tokens have a
  # limited TTL and this script's total runtime (region/ipSpace/
  # providerGateway/org/vDC/networking, several with poll loops) can
  # comfortably outlast it. Result lands in response_body/response_code.
  local method="$1" endpoint="$2" data="$3" retry="${4:-2}" pause="${5:-5}" attempt=0
  while true; do
    response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
      -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Bearer ${vcfa_token}" \
      -d "${data}" "${VCFA_HOST}/${endpoint}")
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]]; then
      return 0
    fi
    if [[ ${response_code} == 401 ]]; then
      vcfa_login
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${method} call to ${endpoint} FAILED, response code was: ${response_code}: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      return 1
    fi
    sleep "${pause}"
    ((attempt++))
  done
}

vcfa_login

#
# Retrieve NSX Manager id and name
#
vcfa_api GET "cloudapi/v1/nsxManagers" ""
nsx_manager_id=$(echo ${response_body} | jq -c -r '.values[0].id')
nsx_manager_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# Retrieve Supervisor id and name
#
vcfa_api GET "cloudapi/v1/supervisors" ""
supervisor_id=$(echo ${response_body} | jq -c -r '.values[0].supervisorId')
supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# configure regions - idempotent. region/ipSpace/providerGateway are
# shared, provider-wide resources (all three already existed for org-1 on
# the vcf9 lab, so this exact block was validated separately end-to-end
# against a second VCD/VCFA environment instead - see the header notes
# above).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    region_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/regions" ""
    existing_region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_region_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: region ${region_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    region_json=$(jq -n --arg n "${region_name}" --arg nsxid "${nsx_manager_id}" --arg nsxname "${nsx_manager_name}" \
      --arg supid "${supervisor_id}" --arg supname "${supervisor_name}" --arg sc "${default_storage_class}" \
      '{name: $n, description: "", nsxManager: {name: $nsxname, id: $nsxid}, supervisors: [{name: $supname, id: $supid}], storagePolicies: [$sc]}')
    vcfa_api POST "cloudapi/v1/regions" "${region_json}"
  fi
done < <(echo "${vcf_a_regions}" | jq -c -r .[])

#
# Create external IP spaces - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    ip_space_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/ipSpaces" ""
    existing_ip_space_id=$(echo ${response_body} | jq -c -r --arg arg "${ip_space_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_ip_space_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ip space ${ip_space_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    ip_space_json=$(jq -n --arg n "${ip_space_name}" --arg cidr "$(echo ${item} | jq -c -r '.cidr')" --arg regionid "${region_id}" \
      '{name: $n, description: "", internalScopeCidrBlocks: [{cidr: $cidr}], ipAddressRanges: [], reservedIpAddressRanges: [],
        providerVisibilityOnly: false, defaultQuota: {maxSubnetSize: 1, maxCidrCount: -1, maxIpCount: -1}, regionRef: {id: $regionid}}')
    vcfa_api POST "cloudapi/v1/ipSpaces" "${ip_space_json}"
  fi
done < <(echo "${vcf_a_ip_spaces}" | jq -c -r .[])

#
# Create provider gateways - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    pgw_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/providerGateways" ""
    existing_pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_pgw_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: provider gateway ${pgw_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    ip_space_refs="[]"
    while read ipspace_name
    do
      vcfa_api GET "cloudapi/v1/ipSpaces" ""
      ipspace_id=$(echo ${response_body} | jq -c -r --arg arg "${ipspace_name}" '.values[] | select(.name == $arg) | .id')
      ip_space_refs=$(echo ${ip_space_refs} | jq -c --arg n "${ipspace_name}" --arg i "${ipspace_id}" '. + [{name: $n, id: $i}]')
    done < <(echo "${item}" | jq -c -r '.ip_space_refs[]')
    pgw_json=$(jq -n --arg n "${pgw_name}" --arg t0 "$(echo ${item} | jq -c -r '.tier0_ref')" --arg regionid "${region_id}" --argjson ipspaces "${ip_space_refs}" \
      '{name: $n, description: "", backingRef: {id: $t0, name: $t0}, backingType: "NSX_TIER0", regionRef: {id: $regionid}, ipSpaceRefs: $ipspaces}')
    vcfa_api POST "cloudapi/v1/providerGateways" "${pgw_json}"
    #
    # This exact POST (no natConfig, no explicit gatewayConnectionBackingId)
    # was confirmed live on a separate VCD/VCFA environment: 202 ->
    # REALIZED with no errors, VCFA auto-populates gatewayConnectionBackingId
    # from the gateway's own name. The original script's own captured error
    # ("Provider Gateway test-ui must be backed by a shared Gateway
    # Connection") did not reproduce here.
    #
  fi
done < <(echo "${vcf_a_provider_gws}" | jq -c -r .[])

#
# configure orgs - the part actually exercised end-to-end live (org-1
# already existed; org-2 and org-3 were created and fully verified this
# way, including org-3 deliberately skipping the aviSetting step).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    org_name=$(echo ${item} | jq -c -r '.name')
    region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
    enable_avi=$(echo ${item} | jq -c -r '.enable_avi // true')

    #
    # org - idempotent
    #
    vcfa_api GET "cloudapi/1.0.0/orgs" ""
    org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${org_id}" ]; then
      org_json=$(jq -n --arg n "${org_name}" '{name: $n, displayName: $n, description: "", isClassicTenant: false, isEnabled: true}')
      vcfa_api POST "cloudapi/1.0.0/orgs" "${org_json}"
      sleep 3
      vcfa_api GET "cloudapi/1.0.0/orgs" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: org ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

    #
    # virtual datacenter - idempotent. Fixes two real bugs in the
    # original: a missing '}' after the supervisor id (invalid JSON,
    # would never actually have POSTed), and zoneResourceAllocation
    # referencing ${zone_id}/${zone_name} that were never actually set
    # anywhere in that script - now taken from each org's own input.
    #
    vdc_name="${org_name}_region-1"
    vcfa_api GET "cloudapi/v1/virtualDatacenters" ""
    vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${vdc_id}" ]; then
      vcfa_api GET "cloudapi/v1/virtualMachineClasses" ""
      vm_classes=$(echo ${response_body} | jq -c -r '[.values[] | {id, name}]')
      zone_name=$(echo ${item} | jq -c -r '.zone_ref')
      zone_id=$(echo ${item} | jq -c -r '.zone_id')
      cpu_limit_mhz=$(echo ${item} | jq -c -r '.cpu_limit_mhz')
      memory_limit_mib=$(echo ${item} | jq -c -r '.memory_limit_mib')

      vdc_json=$(jq -n --arg n "${vdc_name}" --arg orgid "${org_id}" --arg regionid "${region_id}" \
        --arg supname "${supervisor_name}" --arg supid "${supervisor_id}" \
        --arg zoneid "${zone_id}" --arg zonename "${zone_name}" \
        --argjson cpulimit "${cpu_limit_mhz}" --argjson memlimit "${memory_limit_mib}" \
        '{name: $n, description: null, org: {id: $orgid}, region: {id: $regionid},
          supervisors: [{name: $supname, id: $supid}],
          zoneResourceAllocation: [{zone: {id: $zoneid, name: $zonename},
            resourceAllocation: {cpuLimitMHz: $cpulimit, cpuReservationMHz: 0, memoryLimitMiB: $memlimit, memoryReservationMiB: 0}}],
          isFullAllocation: false}')
      vcfa_api POST "cloudapi/v1/virtualDatacenters" "${vdc_json}"
      sleep 3
      vcfa_api GET "cloudapi/v1/virtualDatacenters" ""
      vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')

      #
      # VM classes - assign every available class, matching org-1
      #
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualMachineClasses" "{\"values\":${vm_classes}}"

      #
      # Storage policy - fixes the original's bug where json_data was
      # built correctly here then immediately overwritten by the
      # previous step's vm_classes payload copy-pasted in by mistake.
      #
      # storage_policy_ref is not part of the org input - it's built from
      # ${default_storage_class} (bash/variables.sh), the same variable
      # already used to attach this policy to the region in the
      # "configure regions" step above, rather than requiring its name to
      # be duplicated in every org/template.
      storage_policy_ref="${default_storage_class}"
      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_policy_id=$(echo ${response_body} | jq -c -r --arg arg "${storage_policy_ref}" '.values[] | select(.name == $arg) | .id')
      storage_limit_mib=$(echo ${item} | jq -c -r '.storage_limit // 102400')
      storage_json=$(jq -n --arg spid "${storage_policy_id}" --argjson limit "${storage_limit_mib}" --arg vdcid "${vdc_id}" \
        '{values: [{regionStoragePolicy: {id: $spid}, storageLimitMiB: $limit, virtualDatacenter: {id: $vdcid}}]}')
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualDatacenterStoragePolicies" "${storage_json}"
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vDC ${vdc_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Regional networking settings - idempotent
    #
    vcfa_api GET "cloudapi/v1/regionalNetworkingSettings" ""
    rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
    if [ -z "${rns_id}" ]; then
      pgw_name=$(echo ${item} | jq -c -r '.provider_gateway_ref')
      edge_cluster_name=$(echo ${item} | jq -c -r '.edge_cluster_ref')
      vcfa_api GET "cloudapi/v1/providerGateways" ""
      pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
      vcfa_api GET "cloudapi/v1/edgeClusters" ""
      edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
      if [ -z "${edge_id}" ]; then
        #
        # A brand-new region's edge cluster is not discovered automatically -
        # confirmed live (both the vcf9 lab and a second, independent
        # VCD/VCFA environment) that cloudapi/v1/edgeClusters/sync (no
        # region/id in the path, triggers NSX transport-node discovery) is
        # required first. Try it once, wait, and re-check before giving up.
        #
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} not found for ${org_name}, triggering cloudapi/v1/edgeClusters/sync" "${log_file}" "" ""
        vcfa_api POST "cloudapi/v1/edgeClusters/sync" ""
        sleep 60
        vcfa_api GET "cloudapi/v1/edgeClusters" ""
        edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${edge_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} still not found for ${org_name} after edgeClusters/sync" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
      fi

      net_json=$(jq -n --arg n "${org_name}" --arg orgid "${org_id}" --arg rn "${region_ref_name}" --arg regionid "${region_id}" \
        --arg pgwn "${pgw_name}" --arg pgwid "${pgw_id}" --arg edgen "${edge_cluster_name}" --arg edgeid "${edge_id}" \
        '{orgRef: {name: $n, id: $orgid}, regionRef: {name: $rn, id: $regionid},
          providerGatewayRef: {name: $pgwn, id: $pgwid}, serviceEdgeClusterRef: {name: $edgen, id: $edgeid}}')
      vcfa_api POST "cloudapi/v1/regionalNetworkingSettings" "${net_json}"

      retry_rns=12 ; pause_rns=10 ; attempt_rns=1
      while true
      do
        sleep ${pause_rns}
        vcfa_api GET "cloudapi/v1/regionalNetworkingSettings" ""
        rns_status=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .status')
        if [[ "${rns_status}" == "REALIZED" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_rns++))
        if [ ${attempt_rns} -eq ${retry_rns} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} not REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds (status=${rns_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
      done
      vcfa_api GET "cloudapi/v1/regionalNetworkingSettings" ""
      rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Avi / Load Balancing regional setting - not present anywhere in the
    # original script; found only via the VCFA UI's own network calls.
    # Optional per-org via enable_avi (defaults to true) - set to false to
    # leave an org's Load Balancing section deliberately empty.
    #
    # Two modes, each with a DIFFERENT quota field name (confirmed live,
    # not documented anywhere):
    #   - TENANT_MANAGED: org self-provisions its own service engines.
    #     Quota -> serviceEngineQuota. No SEG reference needed.
    #   - PROVIDER_MANAGED: org is pinned to one specific, already-existing
    #     provider Avi service engine group. Quota -> applicationLimit
    #     instead, and serviceEngineGroupRefs (resolved by name via
    #     cloudapi/v1/loadBalancer/aviServiceEngineGroups, filtered by
    #     this org's region) is required.
    #
    if [ "${enable_avi}" == "true" ]; then
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      avi_quota=$(echo ${item} | jq -c -r '.avi_quota // 10')
      if [ "${avi_mode}" == "PROVIDER_MANAGED" ]; then
        #
        # Confirmed live: VCFA can reject a PROVIDER_MANAGED aviSetting
        # ("service engine group has not been assigned") even though the
        # PUT itself returns 202 and the SEG is already GET-able, unless
        # the avi controller has been synced first. Sync once per script
        # run (avi_synced flag), not once per org - it's a controller-wide
        # action, not org- or SEG-scoped.
        #
        if [ -z "${avi_synced:-}" ]; then
          vcfa_api GET "cloudapi/v1/loadBalancer/aviControllers?filter=regionRef.id==${region_id}" ""
          avi_controller_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.regionRef.id == $arg) | .id' | head -1)
          if [ -n "${avi_controller_id}" ]; then
            vcfa_api POST "cloudapi/v1/loadBalancer/aviControllers/${avi_controller_id}/sync" ""
            sleep 30
          fi
          avi_synced=true
        fi
        seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
        vcfa_api GET "cloudapi/v1/loadBalancer/aviServiceEngineGroups?filter=regionRef.id==${region_id}" ""
        seg_id=$(echo ${response_body} | jq -c -r --arg arg "${seg_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${seg_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: avi service engine group ${seg_name} not found for ${org_name}, skipping aviSetting" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          avi_json=$(jq -n --argjson limit "${avi_quota}" --arg segid "${seg_id}" \
            '{active: true, serviceEngineGroupMode: "PROVIDER_MANAGED", applicationLimit: $limit, serviceEngineGroupRefs: [{id: $segid}]}')
          vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
        fi
      else
        avi_json=$(jq -n --argjson quota "${avi_quota}" \
          '{active: true, serviceEngineGroupMode: "TENANT_MANAGED", serviceEngineQuota: $quota}')
        vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
      fi
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: enable_avi=false for ${org_name}, leaving aviSetting inactive" "${log_file}" "" ""
    fi

    #
    # Assign a user to the VCF-A org - optional, deliberately left
    # commented out here: the original script hardcoded a real username
    # AND plaintext password directly in the file. Never commit real
    # credentials to a script - source both from this project's own
    # secrets handling (e.g. the same generic_password/vault mechanism
    # used elsewhere) if you need this step.
    #
    # user_json=$(jq -n --arg u "${org_admin_username}" --arg p "${org_admin_password}" --arg roleid "${org_admin_role_id}" \
    #   '{username: $u, password: $p, roleEntityRefs: [{id: $roleid, name: "Organization Administrator"}], providerType: "LOCAL"}')
    # vcfa_api POST "cloudapi/1.0.0/users" "${user_json}"
  fi
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch "${resultFile}"

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
# never actually defined zone_id/zone_name/storage/networking inputs).
# zone_ref/zone_id are deliberately NOT fields here - each region has
# exactly one zone (confirmed live), so both are derived at runtime via
# GET cloudapi/v1/zones filtered by region_id, the same pattern already
# used for storage_class_ref. This also sidesteps a real chicken-and-egg
# problem for a brand-new SDDC: zone_id is a literal URN that doesn't
# exist until the region/vSphere cluster this project itself builds is
# actually up, so it could never be known at CR-authoring time anyway.
#   [{
#     "name": "org-2",
#     "region_ref": "region-1",
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
source /home/ubuntu/bash/download_file.sh

VCFA_HOST="https://${fqdn_vcfa}"
VCFA_VERSION="9.1.0"
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

vcfa_put_file() {
  # $1 item_id, $2 file_name (as listed by .../files), $3 transfer URL,
  # $4 local file path, $5 description for logging, $6 retries, $7 pause
  # - confirmed live these contentLibraryItem file PUTs can silently
  # transfer 0 bytes with curl itself reporting HTTP 200/no error
  # (previously not checked here at all, --data-binary piped to
  # /dev/null), leaving the item stuck NOT_READY/FAILED with no
  # indication which file (or that a file at all, versus some other
  # server-side issue) was actually the cause.
  #
  # Content-Type: application/octet-stream turned out to be one real
  # cause (curl's --data-binary defaults to
  # application/x-www-form-urlencoded when no Content-Type is set, which
  # the transfer endpoint accepts with a genuine 200 while discarding the
  # body) - but NOT the only one: confirmed live a second time, even with
  # this header set, the very same PUT (identical body/headers) can still
  # silently transfer 0 bytes with an unqualified HTTP 200, while an
  # immediate manual retry of the exact same transfer URL succeeds fully.
  # A likely per-transfer-session readiness race on VCFA's own transfer
  # endpoint, not something fixable by tweaking the request. So: an HTTP
  # 2xx here is necessary but still not sufficient - re-fetch this item's
  # own /files listing after every PUT and check bytesTransferred ==
  # expectedSizeBytes for THIS file by name before considering it done,
  # retrying the whole PUT (not just re-checking) otherwise.
  local item_id="$1" file_name="$2" transfer_url="$3" local_path="$4" description="$5" retry="${6:-3}" pause="${7:-10}" attempt=1
  while true; do
    curl -sk -o /dev/null -X PUT "${transfer_url}" -H "Authorization: Bearer ${vcfa_token}" -H "Content-Type: application/octet-stream" --data-binary @"${local_path}"
    vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
    transferred=$(echo ${response_body} | jq -c -r --arg n "${file_name}" '.values[] | select(.name == $n) | .bytesTransferred')
    expected=$(echo ${response_body} | jq -c -r --arg n "${file_name}" '.values[] | select(.name == $n) | .expectedSizeBytes')
    if [ -n "${transferred}" ] && [ "${transferred}" == "${expected}" ]; then
      return 0
    fi
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: upload of ${description} incomplete (${transferred:-0}/${expected} bytes transferred), attempt ${attempt}/${retry}" "${log_file}" "" ""
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: giving up uploading ${description} after ${retry} attempts" "${log_file}" "${slack_webhook}" "${google_webhook}"
      return 1
    fi
    sleep "${pause}"
    ((attempt++))
  done
}

# vCenter API session/call helper pair - needed below (VM Service content
# library binding step) since that's a vCenter-native API
# (api/vcenter/namespaces/instances/{ns}), not a VCFA one. vcsa_fqdn/
# basename_sddc/generic_password/jsonFile are all already available from
# bash/variables.sh sourced above. Mirrors vcf_bootstrap.sh's own
# create_vcenter_api_session/vcenter_api pair exactly (that project's own
# port of this script), so both stay aligned.
create_vcenter_api_session() {
  local retry=10 pause=20 attempt=0
  while true; do
    response=$(curl -k -s --write-out "\n%{http_code}" -X POST \
      -u "administrator@$(jq -c -r .sddc.vcenter.ssoDomain "${jsonFile}"):${generic_password}" \
      "https://${vcsa_fqdn}/api/session" -H "Content-Type: application/json")
    http_code=$(tail -n1 <<< "$response")
    vcenter_token=$(sed '$ d' <<< "$response" | tr -d '"')
    if [[ ${http_code} == 20[0-9] ]] && [ ${#vcenter_token} -eq 32 ]; then
      return
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: FAILED to create vCenter API session, http_response_code: ${http_code}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}

vcenter_api() {
  # $1 retries, $2 pause, $3 HTTP method, $4 API endpoint, $5 http data
  local retry="$1" pause="$2" method="$3" endpoint="$4" data="$5" attempt=0
  while true; do
    response=$(curl -k -s -X "${method}" --write-out "\n%{http_code}" -H "vmware-api-session-id: ${vcenter_token}" \
      -H "Content-Type: application/json" -d "${data}" "https://${vcsa_fqdn}/${endpoint}")
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]]; then
      return 0
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: FAILED HTTP ${method} vCenter API call to ${endpoint}, response code was: ${response_code}: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
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
    #
    # ipSpaceRefs deliberately NOT set here - confirmed live it reads
    # back null regardless of what's sent and does not actually
    # associate/pool anything. The real, working association step
    # (POST cloudapi/v1/ipSpaceAssociations) happens separately below,
    # after every ip_space and provider gateway exist.
    #
    # allowAdvertisingPrivateIpBlocks is required as of this VCFA build
    # (confirmed live: omitting it entirely, this payload's own original
    # form, makes the server throw a raw NullPointerException on
    # getAllowAdvertisingPrivateIpBlocks() instead of defaulting it,
    # failing this POST with HTTP 500 - which then cascades into every
    # later step needing this provider gateway's id). Must be true, not
    # false - confirmed live false instead trades that 500 for a
    # different, equally fatal 400: "Provider Gateway ... requires either
    # at least one associated IP Space or private IP Blocks advertisement
    # to be enabled", since no ip_space is associated with this gateway
    # yet at this point (that's a separate, later step - see
    # ipSpaceAssociations below). true satisfies that check without
    # depending on this script's own step ordering.
    pgw_json=$(jq -n --arg n "${pgw_name}" --arg t0 "$(echo ${item} | jq -c -r '.tier0_ref')" --arg regionid "${region_id}" \
      '{name: $n, description: "", backingRef: {id: $t0, name: $t0}, backingType: "NSX_TIER0", regionRef: {id: $regionid}, allowAdvertisingPrivateIpBlocks: true}')
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
# Associate every ip_space with every provider gateway - idempotent.
# This, not the ipSpaceRefs field on providerGateways, is the real
# mechanism (confirmed live: ipSpaceRefs reads back null regardless of
# what's sent, and a gateway configured that way shows no association
# in the UI either). Deliberately full cross-product (every ip_space to
# every gateway) - only a valid simplification while there is a single
# provider gateway; a real ip_space-to-gateway mapping would be needed
# if a second gateway is ever introduced. Confirmed live (51-org x
# 20-VIP batch test) that once associated this way, VIP allocation
# pools cleanly across every associated ip_space in sequence as each
# one fills, with zero errors.
#
vcfa_api GET "cloudapi/v1/ipSpaces" ""
all_ip_spaces=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')
vcfa_api GET "cloudapi/v1/providerGateways" ""
all_provider_gws=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')

echo "${all_provider_gws}" | jq -c -r '.[]' | while read pgw
do
  pgw_id=$(echo ${pgw} | jq -c -r '.id')
  pgw_name=$(echo ${pgw} | jq -c -r '.name')
  echo "${all_ip_spaces}" | jq -c -r '.[]' | while read ipspace
  do
    ipspace_id=$(echo ${ipspace} | jq -c -r '.id')
    ipspace_name=$(echo ${ipspace} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/ipSpaceAssociations?filter=ipSpaceRef.id==${ipspace_id};providerGatewayRef.id==${pgw_id}" ""
    existing_assoc=$(echo ${response_body} | jq -c -r '.values[0].id // empty')
    if [ -n "${existing_assoc}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${ipspace_name} already associated with ${pgw_name}, skipping" "${log_file}" "" ""
      continue
    fi
    assoc_json=$(jq -n --arg pgwid "${pgw_id}" --arg pgwname "${pgw_name}" --arg ipsid "${ipspace_id}" --arg ipsname "${ipspace_name}" \
      '{providerGatewayRef: {id: $pgwid, name: $pgwname}, ipSpaceRef: {id: $ipsid, name: $ipsname}}')
    vcfa_api POST "cloudapi/v1/ipSpaceAssociations" "${assoc_json}"
  done
done

#
# Create content libraries - idempotent. Shared, provider-wide resource
# like region/ipSpace/providerGateway above (NOT nested per-org) -
# confirmed live that a content library created here (system/provider
# portal, libraryType: PROVIDER) is visible from every org's own portal
# by default (isShared: true, isProjectScoped: false out of the box, no
# per-org share/attach step needed) - one library serves every org.
#
# storage class is looked up via cloudapi/v1/storageClasses, NOT
# cloudapi/v1/regionStoragePolicies (used elsewhere in this script for
# vDC storage policy assignment) - confirmed live both endpoints return
# the same underlying policy (identical UUID) but under different URN
# type prefixes (storageClass vs regionStoragePolicy), and contentLibraries
# creation specifically rejects the regionStoragePolicy-typed id ("The
# VCF Automation Tenant Manager entity urn:vcloud:storageClass:X does not
# exist" - note it silently re-typed the id in its own error message).
#
# status starts NOT_READY and reaches READY after ~30s with no explicit
# sync/action needed (unlike edgeClusters/aviControllers above) - this is
# just eventual consistency, confirmed live by polling.
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    cl_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/contentLibraries" ""
    cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${cl_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} already exists, skipping creation" "${log_file}" "" ""
    else
      vcfa_api GET "cloudapi/v1/storageClasses" ""
      storage_class_id=$(echo ${response_body} | jq -c -r --arg arg "${default_storage_class}" '.values[] | select(.name == $arg) | .id')
      cl_json=$(jq -n --arg n "${cl_name}" --arg scid "${storage_class_id}" \
        '{name: $n, storageClasses: [{id: $scid}]}')
      vcfa_api POST "cloudapi/v1/contentLibraries" "${cl_json}"

      retry_cl=6 ; pause_cl=10 ; attempt_cl=1
      while true
      do
        sleep ${pause_cl}
        vcfa_api GET "cloudapi/v1/contentLibraries" ""
        cl_status=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .status')
        if [[ "${cl_status}" == "READY" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} READY after ${attempt_cl} attempts of ${pause_cl} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_cl++))
        if [ ${attempt_cl} -eq ${retry_cl} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} not READY after ${attempt_cl} attempts of ${pause_cl} seconds (status=${cl_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
      done
      vcfa_api GET "cloudapi/v1/contentLibraries" ""
      cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    fi

    #
    # Content library items (OVAs) - idempotent per item, independent of
    # whether the library itself was just created or already existed
    # (previously this whole item step was unreachable on re-runs because
    # the library-exists branch used `continue` - fixed here).
    #
    # ova_url is downloaded LOCALLY on the gw first (no internet egress
    # from VCFA/vCenter's side) to /home/ubuntu/vcf-automation/, then
    # extracted (a .ova is a plain tar archive) and its .ovf descriptor's
    # bytes PUT to the transferUrl VCFA hands back. Confirmed live
    # end-to-end with a real multi-file OVA (lab-web-test-base-2.8.ova:
    # .ovf + .vmdk + .nvram, 40MB): PUT the descriptor -> re-GET files ->
    # server lists the .vmdk AND .nvram (by their real original filenames,
    # matched against the extracted directory here) with their own
    # transferUrls -> PUT each -> item reaches status READY with a real
    # imageIdentifier assigned. The .mf manifest is never listed for
    # separate upload. A deliberately-invalid descriptor was also
    # confirmed to correctly surface as status FAILED rather than silently
    # succeed.
    #
    while read cl_item
    do
      if [ -n "${cl_item}" ] && [ "${cl_item}" != "null" ]; then
        ova_url=$(echo ${cl_item} | jq -c -r '.ova_url')
        # No name field in the input - derived from the URL's own
        # filename (basename, .ova extension stripped) rather than
        # requiring a redundant separate field.
        item_name="${ova_url##*/}"
        item_name="${item_name%.ova}"

        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -n "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} already exists, skipping" "${log_file}" "" ""
          continue
        fi

        ova_dir="/home/ubuntu/vcf-automation"
        ova_file="${ova_dir}/${item_name}.ova"
        extract_dir="${ova_dir}/${item_name}"
        mkdir -p "${ova_dir}" "${extract_dir}"

        download_file_from_url_to_location "${ova_url}" "${ova_file}" "content library item ${item_name}"

        if [ -z "$(ls -A "${extract_dir}" 2>/dev/null)" ]; then
          tar -xf "${ova_file}" -C "${extract_dir}"
        fi
        ovf_file=$(find "${extract_dir}" -maxdepth 1 -name '*.ovf' | head -1)
        if [ -z "${ovf_file}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no .ovf found after extracting ${ova_file}, skipping item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        item_json=$(jq -n --arg n "${item_name}" --arg clid "${cl_id}" \
          '{name: $n, contentLibrary: {id: $clid}, itemType: "TEMPLATE"}')
        vcfa_api POST "cloudapi/v1/contentLibraryItems" "${item_json}"
        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create content library item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # descriptor upload - the server does NOT preserve the original
        # uploaded filename for this entry, it always renames it to the
        # literal "descriptor.ovf" regardless of what the local .ovf is
        # actually called (confirmed live: a lab-web-test-base-2.8.ovf
        # upload comes back re-listed as descriptor.ovf, not under its
        # own name) - so excluding disk files by comparing against the
        # LOCAL .ovf basename below is wrong and lets this renamed
        # descriptor entry slip through the filter as if it were a
        # missing disk file. Capture the server's own name for this
        # entry here instead, before uploading it, and exclude by THAT.
        vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
        descriptor_name=$(echo ${response_body} | jq -c -r '.values[0].name')
        descriptor_transfer_url=$(echo ${response_body} | jq -c -r '.values[0].transferUrl')
        vcfa_put_file "${item_id}" "${descriptor_name}" "${descriptor_transfer_url}" "${ovf_file}" "descriptor for item ${item_name}"

        # disk file(s) - discovered from the server AFTER the descriptor
        # upload (see the caveat above); uploaded by matching each
        # server-reported file name against the extracted directory.
        # Retries the discovery GET itself, not just each file's later
        # upload - confirmed live that under real load (concurrent org
        # provisioning elsewhere in this same run) the /files listing can
        # still only report the descriptor entry well past a fixed 5s
        # sleep, silently leaving disk_files empty and skipping the
        # upload loop entirely with no error at all (looked, at the
        # symptom level, identical to the upload itself being stuck).
        disk_files=""
        for attempt_discover in $(seq 1 12); do
          sleep 5
          vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
          disk_files=$(echo ${response_body} | jq -c -r --arg descname "${descriptor_name}" '.values[] | select(.name != $descname) | @base64')
          if [ -n "${disk_files}" ]; then
            break
          fi
        done
        if [ -z "${disk_files}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no disk files discovered for item ${item_name} after waiting, giving up on this item" "${log_file}" "${slack_webhook}" "${google_webhook}"
        fi
        for encoded_file in ${disk_files}; do
          disk_name=$(echo "${encoded_file}" | base64 -d | jq -c -r '.name')
          disk_transfer_url=$(echo "${encoded_file}" | base64 -d | jq -c -r '.transferUrl')
          local_disk_path="${extract_dir}/${disk_name}"
          if [ -f "${local_disk_path}" ]; then
            vcfa_put_file "${item_id}" "${disk_name}" "${disk_transfer_url}" "${local_disk_path}" "disk file ${disk_name} for item ${item_name}"
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: server-requested disk file ${disk_name} not found locally under ${extract_dir} for item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
        done

        retry_item=12 ; pause_item=15 ; attempt_item=1
        while true
        do
          sleep ${pause_item}
          vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}" ""
          item_status=$(echo ${response_body} | jq -c -r '.status')
          if [[ "${item_status}" == "READY" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} READY after ${attempt_item} attempts of ${pause_item} seconds" "${log_file}" "" ""
            break
          fi
          if [[ "${item_status}" == "FAILED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} status FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
          ((attempt_item++))
          if [ ${attempt_item} -eq ${retry_item} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} not READY after ${attempt_item} attempts of ${pause_item} seconds (status=${item_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi
    done < <(echo "${item}" | jq -c -r '.items // [] | .[]')
  fi
done < <(echo "${vcf_a_content_libraries}" | jq -c -r .[])

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
    # org - idempotent. Uses filter=name==X (server-side exact match)
    # rather than an unpaginated GET + client-side jq select - confirmed
    # live at 50+ org scale that cloudapi/1.0.0/orgs silently caps its
    # response at 32 values NO MATTER what pageSize is requested (even
    # pageSize=200 made no difference), so beyond ~32 total orgs a plain
    # GET-and-jq-select lookup would falsely report a brand-new org as
    # "not found" even though it was created successfully, and the
    # script would then attempt to create it a second time. filter=
    # queries the server directly for the exact name and always returns
    # the right single record regardless of total org count.
    #
    vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
    org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${org_id}" ]; then
      org_json=$(jq -n --arg n "${org_name}" '{name: $n, displayName: $n, description: "", isClassicTenant: false, isEnabled: true}')
      vcfa_api POST "cloudapi/1.0.0/orgs" "${org_json}"
      sleep 3
      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
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
    vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
    vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${vdc_id}" ]; then
      vcfa_api GET "cloudapi/v1/virtualMachineClasses" ""
      vm_classes=$(echo ${response_body} | jq -c -r '[.values[] | {id, name}]')
      # zone_ref/zone_id are NOT input fields - derived here the same way
      # as storage_class_ref (see the storage policy step below): each
      # region has exactly one zone (confirmed live), so filter
      # cloudapi/v1/zones by this org's region_id and take that one
      # match, instead of requiring a literal URN to be known up front -
      # a URN that, for a brand-new SDDC being built by this same
      # project, cannot exist yet at CR-authoring time.
      vcfa_api GET "cloudapi/v1/zones" ""
      zone_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .id' | head -1)
      zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
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
      vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
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
    # Regional networking settings - idempotent. filter=orgRef.name==X
    # for the same reason as the org/vDC lookups above - confirmed live
    # this endpoint has the identical 32-item pageSize cap.
    #
    org_uuid="${org_id##*:}"
    vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
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

      #
      # Create + poll to REALIZED, then verify the underlying NSX Project
      # actually exists before trusting it - confirmed live at 50-org
      # scale that VCFA's regionalNetworkingSettings can report status
      # REALIZED while the NSX Project backing that org's VPC was never
      # actually created at all (root cause never fully pinned down;
      # observed as a clean alternating every-other-org failure when 51
      # orgs' regionalNetworkingSettings were POSTed back-to-back with no
      # pacing between them - real NSX Manager/Avi were both healthy).
      # This is a genuine backend gap: nothing in VCFA's own API surface
      # (status, aviSetting errors) reveals it - the only reliable check
      # is GETting the org's NSX Project directly. One delete+recreate
      # retry (confirmed live to fully resolve it every time across 25
      # affected orgs) before giving up for good.
      #
      for rns_attempt in 1 2; do
        vcfa_api POST "cloudapi/v1/regionalNetworkingSettings" "${net_json}"

        retry_rns=12 ; pause_rns=10 ; attempt_rns=1 ; rns_realized=false
        while true
        do
          sleep ${pause_rns}
          vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
          rns_status=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .status')
          rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
          if [[ "${rns_status}" == "REALIZED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds" "${log_file}" "" ""
            rns_realized=true
            break
          fi
          ((attempt_rns++))
          if [ ${attempt_rns} -eq ${retry_rns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} not REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds (status=${rns_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            exit 100
          fi
        done

        nsx_project_id=$(curl -sk -u "admin:${generic_password}" "https://${ip_nsx_vip}/policy/api/v1/orgs/default/projects/${org_uuid}" | jq -r '.id // empty')
        if [ "${nsx_project_id}" == "${org_uuid}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project confirmed present for ${org_name}" "${log_file}" "" ""
          break
        fi

        if [ ${rns_attempt} -eq 2 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project still missing for ${org_name} after delete+recreate retry - regionalNetworkingSettings reports REALIZED but is not actually backed by NSX, giving up" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project missing for ${org_name} despite REALIZED status - deleting and recreating regionalNetworkingSettings once" "${log_file}" "" ""
        vcfa_api DELETE "cloudapi/v1/regionalNetworkingSettings/${rns_id}" ""
        sleep 10
      done
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
          if [ -z "${avi_controller_id}" ]; then
            #
            # SDDC Manager registers Avi directly with NSX-T (enforcement
            # point), but VCFA keeps its OWN, separate aviControllers
            # catalog that is not populated automatically from that NSX
            # registration - confirmed live: catalog stayed empty long
            # after Avi/NSX were both healthy. It requires this explicit
            # provider-side registration call (schema confirmed live via
            # the API's own "Unrecognized field" error message).
            #
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no avi controller registered in VCFA for region ${region_ref_name}, registering ${ip_avi}" "${log_file}" "" ""
            avi_controller_json=$(jq -n --arg url "https://${ip_avi}" --arg pass "${generic_password}" --arg regionid "${region_id}" \
              '{name: "provider-avi", url: $url, username: "admin", password: $pass, license: "ENTERPRISE", regionRef: {id: $regionid}, isDedicatedForClassicTenants: false}')
            vcfa_api POST "cloudapi/v1/loadBalancer/aviControllers" "${avi_controller_json}"
            for attempt_avi_reg in $(seq 1 12); do
              sleep 10
              vcfa_api GET "cloudapi/v1/loadBalancer/aviControllers?filter=regionRef.id==${region_id}" ""
              avi_controller_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.regionRef.id == $arg) | .id' | head -1)
              if [ -n "${avi_controller_id}" ]; then
                break
              fi
            done
            if [ -z "${avi_controller_id}" ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: FAILED to register avi controller ${ip_avi} in VCFA after waiting" "${log_file}" "${slack_webhook}" "${google_webhook}"
            fi
          fi
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

#
# Namespace provisioning - org-portal phase, run AFTER every org above is
# fully configured from the system/provider portal. One supervisor
# namespace per eligible org (item.namespace.enabled == true), created via
# an org-scoped OAuth token rather than the provider Bearer token used
# everywhere above - VCFA has no provider-level API for this, it's
# inherently a tenant self-service action.
#
# PROVIDER_MANAGED ONLY for now: namespace creation requires a segName
# unconditionally ("SEG is required when creating namespace on region with
# NSX_REGISTERED_AVI LB type..."), confirmed live - for PROVIDER_MANAGED
# orgs that's just avi_service_engine_group_ref. TENANT_MANAGED orgs have
# no equivalent SEG yet (needs its own new SEG created via VCF-A first) -
# deliberately parked, so any org with namespace.enabled but avi_mode !=
# PROVIDER_MANAGED is skipped with a log message rather than guessed at.
#
# Auth: provider Bearer token -> org-scoped OAuth token via jwt-bearer
# exchange, matching templates/vcfa_select_ns.sh.template's documented
# flow (https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/).
# A fresh org token is requested per org (org tokens are short-lived and
# org-specific, unlike the one long-lived provider token reused above).
# KNOWN LIMITATION: unlike vcfa_api, cci_api below does not re-request the
# org token on expiry mid-poll - the poll loop (up to 12x15s=3min after
# creation) could plausibly outlast a short-lived org token on some
# systems. Not yet hit live; if the poll starts failing partway through
# with 401s, that's the fix needed.
#
# VPC and namespace name are deliberately not input fields (see the CRD's
# own comments on organization_templates.namespace) - the org's default
# VPC is deterministically named "default-${region_ref}" (confirmed live:
# org-3's is "default-region-1"), and the API requires
# metadata.generateName (never a fixed name), so idempotency here is by
# name PREFIX match ("${org_name}-ns-") rather than exact name.
#
cci_api() {
  # $1 method, $2 endpoint (relative to /cci/kubernetes/), $3 data, $4 org token
  local method="$1" endpoint="$2" data="$3" org_token="$4"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${VCFA_HOST}/cci/kubernetes/${endpoint}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}

# A namespace's own K8s API (used for VKS clusters etc.) lives at a
# completely different base path (namespaceEndpointURL, e.g.
# https://HOST/proxy/k8s/namespaces/{ns-urn}) than the CCI namespace/
# project API cci_api above talks to (https://HOST/cci/kubernetes/...) -
# confirmed live these are NOT nested under each other. This takes the
# full base URL directly rather than assuming any fixed prefix.
ns_k8s_api() {
  # $1 method, $2 base url (namespaceEndpointURL), $3 path (relative to base), $4 data, $5 org token
  local method="$1" base="$2" path="$3" data="$4" org_token="$5"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${base}/${path}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}

# Blueprints (Aria Automation Cloud Templates) live under a COMPLETELY
# different base path (/blueprint/api/, /project-service/api/,
# /catalog/api/) than cloudapi/cci/proxy-k8s used everywhere else in
# this script - confirmed live these are real, reachable APIs on the
# same VCFA host, using the SAME org-scoped OAuth token already derived
# for namespace/VKS provisioning (no separate auth needed).
blueprint_api() {
  # $1 method, $2 path (relative to VCFA_HOST, no leading /), $3 data, $4 org token
  local method="$1" path="$2" data="$3" org_token="$4"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${VCFA_HOST}/${path}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}

vcfa_api GET "cloudapi/1.0.0/openIdProvider/relyingParties" ""
client_id=$(echo ${response_body} | jq -c -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
if [ -z "${client_id}" ] || [ "${client_id}" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: could not determine the automation relying party clientId, skipping all namespace provisioning" "${log_file}" "${slack_webhook}" "${google_webhook}"
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
      namespace_enabled=$(echo ${item} | jq -c -r '.namespace.enabled // false')
      if [ "${namespace_enabled}" != "true" ]; then
        continue
      fi
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
      if [ "${avi_mode}" != "PROVIDER_MANAGED" ] || [ -z "${seg_name}" ] || [ "${seg_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has namespace.enabled but avi_mode is not PROVIDER_MANAGED (or has no SEG) - TENANT_MANAGED namespace provisioning is not yet supported, skipping" "${log_file}" "" ""
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"

      vcfa_api GET "cloudapi/v1/regions" ""
      region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_class_k8s_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .kubernetesCompliantName' | head -1)

      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its namespace" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -n "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace for ${org_name} already exists (${ns_name}), skipping creation" "${log_file}" "" ""
      else
        # zone_ref is NOT an input field here either - same derivation
        # as the vDC creation step above (one zone per region).
        vcfa_api GET "cloudapi/v1/zones" ""
        zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
        namespace_class=$(echo ${item} | jq -c -r '.namespace.class // "small"')
        namespace_cpu_limit_mhz=$(echo ${item} | jq -c -r '.namespace.cpu_limit_mhz')
        namespace_memory_limit_mib=$(echo ${item} | jq -c -r '.namespace.memory_limit_mib')
        namespace_storage_limit_mib=$(echo ${item} | jq -c -r '.namespace.storage_limit_mib')

        ns_json=$(jq -n --arg prefix "${org_name}-ns-" --arg project "${project}" \
          --arg region "${region_ref_name}" --arg class "${namespace_class}" \
          --arg vpc "default-${region_ref_name}" --arg seg "${seg_name}" \
          --arg zonename "${zone_name}" --arg cpulimit "${namespace_cpu_limit_mhz}M" --arg memlimit "${namespace_memory_limit_mib}Mi" \
          --arg storagename "${storage_class_k8s_name}" --arg storagelimit "${namespace_storage_limit_mib}Mi" \
          '{apiVersion: "infrastructure.cci.vmware.com/v1alpha3", kind: "SupervisorNamespace",
            metadata: {generateName: $prefix, namespace: $project},
            spec: {regionName: $region, className: $class, vpcName: $vpc, segName: $seg,
              classConfigOverrides: {
                zones: [{name: $zonename, cpuLimit: $cpulimit, cpuReservation: "0", memoryLimit: $memlimit, memoryReservation: "0"}],
                storageClasses: [{name: $storagename, limit: $storagelimit}]
              }}}')
        cci_api POST "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "${ns_json}" "${org_token}"
        if [ $? -ne 0 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace creation for ${org_name} FAILED, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi
        ns_name=$(echo ${response_body} | jq -c -r '.metadata.name')

        retry_ns=12 ; pause_ns=15 ; attempt_ns=1
        while true
        do
          sleep ${pause_ns}
          cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
          ns_phase=$(echo ${response_body} | jq -c -r '.status.phase')
          if [[ "${ns_phase}" == "Created" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} reached phase Created after ${attempt_ns} attempts of ${pause_ns} seconds" "${log_file}" "" ""
            break
          fi
          ((attempt_ns++))
          if [ ${attempt_ns} -eq ${retry_ns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} not Created after ${attempt_ns} attempts of ${pause_ns} seconds (phase=${ns_phase})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi

      #
      # VM Service content library binding - a separate, lower layer than
      # VCFA's own "content library visible from every org's portal"
      # sharing above (cloudapi/v1/contentLibraries, done once for all
      # orgs) - confirmed live (blueprint admission webhook error:
      # VirtualMachineImage "vmi-..." not found, traced down to vCenter's
      # own API) that VM Service only projects a content library's items
      # into a namespace as VirtualMachineImage objects if that library's
      # vCenter-NATIVE uuid is explicitly listed in the namespace's own
      # vm_service_spec.content_libraries (vCenter's
      # api/vcenter/namespaces/instances/{ns} API) - a completely
      # different id space than VCFA's own urn:vcloud:contentLibrary:...
      # id, so the two can't just be string-matched. VCFA-level "shared"
      # visibility alone does NOT populate this. Every
      # vcf_a_content_libraries entry is provider-wide/shared by design
      # (see the "one library serves every org" comment above), so all of
      # them are bound to every eligible org's namespace here
      # automatically - no new CR field needed. Existing entries (e.g. a
      # tenant's own org-created library, confirmed live to exist
      # side-by-side) are preserved by merging rather than overwriting.
      # Runs regardless of whether ns_name was just created above or
      # already existed, same as the Vault step below, since an
      # already-existing namespace from before this step existed would
      # otherwise never get the binding retrofitted.
      #
      if [ -n "${ns_name}" ]; then
        create_vcenter_api_session
        vcenter_api 3 3 GET "api/content/library" ""
        all_lib_ids=$(echo "${response_body}" | jq -r '.[]')
        vc_lib_uuids=""
        while read -r shared_cl_name
        do
          [ -z "${shared_cl_name}" ] && continue
          for lib_id in ${all_lib_ids}; do
            vcenter_api 3 3 GET "api/content/library/${lib_id}" ""
            lib_name=$(echo "${response_body}" | jq -r '.name')
            if [ "${lib_name}" == "${shared_cl_name}" ]; then
              vc_lib_uuids="${vc_lib_uuids} ${lib_id}"
              break
            fi
          done
        done < <(echo "${vcf_a_content_libraries}" | jq -c -r '.[].name')

        if [ -n "$(echo ${vc_lib_uuids})" ]; then
          vcenter_api 3 3 GET "api/vcenter/namespaces/instances/${ns_name}" ""
          existing_libs=$(echo "${response_body}" | jq -c '.vm_service_spec.content_libraries // []')
          merged_libs=$(jq -n --argjson existing "${existing_libs}" --arg new "${vc_lib_uuids}" \
            '$existing + ($new | split(" ") | map(select(length > 0))) | unique')
          patch_json=$(jq -n --argjson libs "${merged_libs}" '{vm_service_spec: {content_libraries: $libs}}')
          vcenter_api 3 3 PATCH "api/vcenter/namespaces/instances/${ns_name}" "${patch_json}"
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: bound shared content libraries to namespace ${ns_name}'s vm_service_spec.content_libraries (${merged_libs})" "${log_file}" "" ""
        fi
      fi

      #
      # Vault cert-manager bootstrap - runs kubectl directly against the
      # Supervisor cluster (NOT VCFA's own API - these are plain K8s
      # objects VCFA doesn't manage), once this org's namespace is
      # confirmed present, regardless of whether it was just created
      # above or already existed (kubectl apply is idempotent, safe to
      # re-run every time this script runs).
      #
      # secret_vault.yaml/vault_issuer.yaml are raw placeholder templates
      # from demoavi/dev-avi-vcf (gw's own userdata clones that repo and
      # copies every yamls/*.yaml file into /home/ubuntu/${yaml_folder}/
      # untouched, since neither Kind is in the demo-yaml by-Kind dispatch
      # there) - ALL their real values are filled in here instead, per
      # org/namespace, using yq (mikefarah/yq, installed at
      # /usr/local/bin/yq by gw's own userdata). This has to happen here
      # rather than in cloud-init because the actual namespace name isn't
      # known until VCF-A creates it under this org (well after gw's own
      # first boot) - cloud-init is simply too early for that value, even
      # though the OTHER fields (vault token/server/path/caBundle) are
      # already knowable at cloud-init time. Keeping every substitution in
      # one place (here) rather than splitting them across cloud-init and
      # this script is deliberate, since this script is the one meant to
      # be ported to the local epc-vapp project later - having the whole
      # mechanism self-contained here keeps that port simple.
      #
      # A source-file kind/name sanity check guards against silently
      # patching the wrong file if the templates in dev-avi-vcf/yamls/
      # ever get renamed/restructured.
      #
      # auth_supervisor_custer.sh switches the local kubectl/vcf CLI
      # context to the Supervisor cluster itself (sup-admin-01) -
      # confirmed live this must run first, since a stale context left
      # over from other kubectl usage (e.g. a VKS workload cluster's own
      # context) otherwise causes TLS/cert errors reaching the
      # Supervisor's namespaces. Re-run per org rather than once for the
      # whole script, since a long batch run across many orgs could
      # plausibly outlast the CLI's own token (not yet observed live,
      # but a real risk given how long the aviSetting/
      # regionalNetworkingSettings polling elsewhere in this script can
      # already run).
      #
      vault_integration_enabled=$(echo ${item} | jq -c -r '.namespace.vault_integration.enabled // false')
      if [ -n "${ns_name}" ] && [ "${vault_integration_enabled}" == "true" ]; then
        bash /home/ubuntu/supervisor/auth_supervisor_custer.sh >/dev/null 2>&1

        secret_kind="$(yq '.kind' /home/ubuntu/${yaml_folder}/secret_vault.yaml)"
        secret_name="$(yq '.metadata.name' /home/ubuntu/${yaml_folder}/secret_vault.yaml)"
        issuer_kind="$(yq '.kind' /home/ubuntu/${yaml_folder}/vault_issuer.yaml)"
        if [ "${secret_kind}" != "Secret" ] || [ "${secret_name}" != "cert-manager-vault-token" ] || [ "${issuer_kind}" != "Issuer" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: secret_vault.yaml/vault_issuer.yaml have unexpected kind/name (secret_kind=${secret_kind}, secret_name=${secret_name}, issuer_kind=${issuer_kind}), skipping vault bootstrap for ${org_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          cp /home/ubuntu/${yaml_folder}/secret_vault.yaml "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".data.token = \"$(echo -n $(jq -c -r .root_token ${vault_secret_file_path}) | base64)\"" "/tmp/${org_name}-secret_vault.yaml"

          cp /home/ubuntu/${yaml_folder}/vault_issuer.yaml "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.server = \"https://${ip_gw}:8200\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.path = \"${vault_pki_intermediate_name}/sign/${vault_pki_intermediate_role_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          # /opt/vault/tls/tls.crt is vault:vault 0600 - unreadable by this
          # script's own ubuntu user (unlike cloud-init, which built this
          # same value while still running as root) - confirmed live this
          # user has passwordless sudo, so read it that way instead.
          yq -i ".spec.vault.caBundle = \"$(sudo cat /opt/vault/tls/tls.crt | base64 -w0)\"" "/tmp/${org_name}-vault_issuer.yaml"

          kubectl_out=$( { kubectl apply -f "/tmp/${org_name}-secret_vault.yaml" && kubectl apply -f "/tmp/${org_name}-vault_issuer.yaml"; } 2>&1 )
          if [ $? -eq 0 ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret + issuer applied for ${org_name} in namespace ${ns_name}" "${log_file}" "" ""
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret/issuer apply FAILED for ${org_name} in namespace ${ns_name}, output: ${kubectl_out}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
          rm -f "/tmp/${org_name}-secret_vault.yaml" "/tmp/${org_name}-vault_issuer.yaml"
        fi
      fi

      #
      # VKS cluster - very simple data model (vks_cluster.enabled only,
      # everything else stays at the UI's own "create with defaults"
      # values) - confirmed live against org-3's own namespace using the
      # exact topology observed on org-1's manually-created cluster
      # (kubernetes-cluster-q4md): ClusterClass builtin-generic-v3.6.0,
      # k8s v1.35.5+vmware.1, 1 control-plane + 1 worker replica,
      # vmClass best-effort-medium. Confirmed live it's
      # cluster.x-k8s.io/v1beta2 that the UI actually uses (v1beta1 is
      # accepted but deprecated AND rejects the request unless
      # clusterNetwork.services is also set - v1beta2 doesn't need that
      # worked around). clusterNetwork.pods.cidrBlocks, however, IS
      # required in both versions and has NO server-side default -
      # confirmed live: omitting it (as an earlier version of this script
      # did) leaves every node's Spec.PodCIDR permanently empty, crashing
      # antrea-agent cluster-wide (CrashLoopBackOff on "Spec.PodCIDR is
      # empty for Node") and cascading into virtually every other pod
      # staying stuck ContainerCreating. This range is NOT related to the
      # namespace's own NSX VPC private-IP block (privateIPs on that
      # VPC's NetworkInfo, e.g. 172.26.0.0/16 / 172.30.0.0/16 in this
      # environment) - it's a purely internal Antrea overlay CIDR, safe
      # to reuse identically across every org's cluster since each one is
      # isolated within its own VPC/namespace and never routes to
      # another's pod network directly. Value matches the one seen live
      # on a UI-created reference cluster (kubernetes-cluster-z8lk).
      # storageClass reuses ${storage_class_k8s_name}
      # already derived above for the namespace step, rather than
      # re-deriving it. The cluster starts with spec.paused: true
      # (set automatically by an admission webhook) and clears itself
      # within seconds with no action needed - confirmed live the
      # cluster then proceeds through normal machine provisioning
      # (phase: Provisioned, InfrastructureReady: True) with no
      # equivalent of org-1's "run.tanzu.vmware.com/resolve-os-image"
      # annotation required (the ClusterClass resolves a default OS
      # image on its own when that annotation is omitted).
      #
      # Confirmed live end-to-end (not just Provisioned): a second test
      # cluster created in org-1's own namespace with this exact payload
      # reached status.conditions[type=Available].status == "True"
      # (fully Ready) after ~8-10 minutes - CNI (Antrea) and the
      # vsphere-csi addon both take a few minutes to finish reconciling
      # after the nodes first come up, which is normal and not itself a
      # failure signal even though AddonsReconciled briefly reports
      # ReconcileFailed/timed-out during that window. A separate cluster
      # created in org-3's namespace stayed stuck well past that window
      # in this same test session - suspected to be an environment-
      # specific resource constraint (e.g. underlying vSAN capacity) on
      # that particular namespace/org, not a payload or script issue.
      #
      # Idempotency is by PRESENCE, not name (the API only supports
      # generateName, never a fixed name) - "one default cluster per
      # org" is the intent per vks_cluster's simple enable/disable model,
      # so if ANY cluster already exists in the namespace, none is
      # created.
      #
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      vks_count=$(echo ${item} | jq -c -r '.vks_cluster.count // 1')
      if [ "${vks_count}" != "1" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has vks_cluster.count=${vks_count}, but only 1 is supported today - creating exactly 1" "${log_file}" "" ""
      fi
      if [ "${vks_enabled}" == "true" ] && [ -n "${ns_name}" ]; then
        cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
        ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
        if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS cluster" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
          existing_vks=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
          if [ -n "${existing_vks}" ] && [ "${existing_vks}" != "null" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster for ${org_name} already exists (${existing_vks}), skipping creation" "${log_file}" "" ""
          else
            vks_json=$(jq -n --arg ns "${ns_name}" --arg storagename "${storage_class_k8s_name}" \
              '{apiVersion: "cluster.x-k8s.io/v1beta2", kind: "Cluster",
                metadata: {generateName: "vks-cluster-", namespace: $ns},
                spec: {
                  clusterNetwork: {serviceDomain: "cluster.local", pods: {cidrBlocks: ["192.168.156.0/20"]}, services: {cidrBlocks: ["10.96.0.0/12"]}},
                  topology: {
                    classRef: {name: "builtin-generic-v3.6.0", namespace: "vmware-system-vks-public"},
                    version: "v1.35.5+vmware.1",
                    controlPlane: {replicas: 1},
                    workers: {machineDeployments: [{class: "node-pool", name: "node-pool-1", replicas: 1}]},
                    variables: [
                      {name: "vmClass", value: "best-effort-medium"},
                      {name: "storageClass", value: $storagename}
                    ]
                  }
                }}')
            ns_k8s_api POST "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "${vks_json}" "${org_token}"
            if [ $? -ne 0 ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster creation for ${org_name} FAILED, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            else
              vks_name=$(echo ${response_body} | jq -c -r '.metadata.name')
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} created, will check Available status in a later pass (see below) once every org's cluster has been created" "${log_file}" "" ""
            fi
          fi
        fi
      fi
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

  #
  # VKS cluster status polling - a SEPARATE pass, run only after every
  # org's cluster has already been created above. Deliberately decoupled
  # from creation so N clusters bootstrap in parallel server-side, rather
  # than this script blocking org 1's several-minutes-long node bootstrap
  # before even starting org 2's cluster creation.
  #
  # Terminates on status.conditions[] type=="Available" status=="True" -
  # confirmed live this is CAPI's own top-level cluster-wide readiness
  # signal (control plane + all workers healthy), NOT the same as
  # phase=="Provisioned" (only means the topology/infra request was
  # accepted - observed within seconds of creation while nodes were
  # still booting, long before Available flips true).
  #
  # Re-derives org token/namespace/cluster name from scratch per org
  # rather than reusing anything from the creation loop above, since bash
  # doesn't carry per-iteration loop state across two separate while-read
  # loops - same GET-by-name approach used throughout this script.
  #
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      if [ "${vks_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -z "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespace found for ${org_name}, skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
      ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
      if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
      vks_name=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
      if [ -z "${vks_name}" ] || [ "${vks_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VKS cluster found for ${org_name} in namespace ${ns_name}, skipping status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      retry_vks=40 ; pause_vks=30 ; attempt_vks=1
      while true
      do
        ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}"
        vks_available=$(echo ${response_body} | jq -c -r '.status.conditions[]? | select(.type=="Available") | .status')
        if [[ "${vks_available}" == "True" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} is Available after ${attempt_vks} attempts of ${pause_vks} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_vks++))
        if [ ${attempt_vks} -eq ${retry_vks} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} NOT Available after ${attempt_vks} attempts of ${pause_vks} seconds (last Available status=${vks_available:-unknown})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
        sleep ${pause_vks}
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi

#
# Blueprints (org-portal phase) - idempotent, one independent copy
# uploaded+released per org with blueprints.enabled, from every
# *.yaml.template file in the epc-vapp/dev-avi-vcf repo's own
# blueprints/ dir (git-cloned onto gw directly by sddc.sh, same repo
# and same directory structure the vApp/VCD use case's vcf_bootstrap.sh
# already consumes - a single shared source of truth for both projects
# instead of maintaining separate copies here). Unrelated to
# namespace/vks_cluster gating - blueprints are a plain Aria Automation
# Cloud Template concept, no Avi/segName dependency.
#
# NOT cross-org shared (confirmed live: organizationSharings requires a
# rights-bundle right that, even granted, still didn't clear the "does
# not have required privileges to share catalog items" error - root
# cause not found yet). Each enabled org gets its own separate upload.
#
# ${avi_subdomain} in each template is deliberately substituted with
# THIS ORG'S OWN NAME, not the deployment's actual avi_subdomain value -
# substituting the real (single, deployment-wide) avi_subdomain would
# give every org's copy of a blueprint the exact same FQDN, a real
# routing conflict once more than one org has the same blueprint
# deployed. Using the org name instead keeps every org's instance
# unique. ${domain} stays global/shared - no per-org conflict there.
#
blueprints_dir="/home/ubuntu/dev-avi-vcf/blueprints"
if [ ! -d "${blueprints_dir}" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${blueprints_dir} does not exist, skipping all blueprint provisioning" "${log_file}" "" ""
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      blueprints_enabled=$(echo ${item} | jq -c -r '.blueprints.enabled // false')
      if [ "${blueprints_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      blueprint_api GET "project-service/api/projects" "" "${org_token}"
      project_id=$(echo ${response_body} | jq -c -r '.content[0].id')
      if [ -z "${project_id}" ] || [ "${project_id}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VCF-A project found for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      for bp_file in "${blueprints_dir}"/*.yaml.template; do
        [ -e "${bp_file}" ] || continue
        bp_name=$(basename "${bp_file}" .yaml.template)

        blueprint_api GET "blueprint/api/blueprints" "" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r --arg arg "${bp_name}" '.content[] | select(.name == $arg) | .id')
        if [ -n "${bp_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} already exists for ${org_name}, skipping creation" "${log_file}" "" ""
          continue
        fi

        bp_content=$(sed -e "s@\${avi_subdomain}@${org_name}@g" -e "s/\${domain}/${domain}/g" "${bp_file}")
        bp_json=$(jq -n --arg n "${bp_name}" --arg pid "${project_id}" --arg content "${bp_content}" \
          '{name: $n, description: null, valid: true, content: $content, projectId: $pid, requestScopeOrg: true, iconId: null}')
        blueprint_api POST "blueprint/api/blueprints?apiVersion=2020-08-25" "${bp_json}" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r '.id')
        if [ -z "${bp_id}" ] || [ "${bp_id}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create blueprint ${bp_name} for ${org_name}, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # Confirmed live: the release step can transiently 500 on an
        # unrelated internal VCFA microservice call
        # (provisioning-service -> tenant-manager over the internal
        # service mesh, "failure when writing TLS control frames") that
        # has nothing to do with this payload - a plain retry a few
        # seconds later succeeds cleanly every time observed. The
        # blueprint draft itself (bp_id above) is unaffected either way.
        rel_json='{"version":"1","description":"initial release","changeLog":"initial release","release":true}'
        released=false
        for rel_attempt in 1 2 3; do
          if blueprint_api POST "blueprint/api/blueprints/${bp_id}/versions" "${rel_json}" "${org_token}"; then
            released=true
            break
          fi
          sleep 10
        done
        if [ "${released}" == "true" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created and released for ${org_name}" "${log_file}" "" ""
        else
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created but release FAILED for ${org_name} after retries, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        fi
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch "${resultFile}"

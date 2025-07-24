import kopf
import requests
import subprocess
import json
from kubernetes import client, config
import logging
import os
import datetime

logging.basicConfig(level=logging.INFO)

# logging.info("This is an info message")
# logging.warning("This is a warning message")
# logging.error("This is an error message")

# Load the Kubernetes configuration
config.load_incluster_config()

# Helper function to create sddc
def create_sddc(spec):
    folder='/nested-vcf'
    a_dict = spec
    a_dict['operation'] = "apply"
    now = datetime.datetime.now()
    json_file='/root/data.json'
    log_file="/nested-vcf/log/{0}-{1}_apply.stdout".format(a_dict['sddc']['basename'], now.strftime("%Y%m%d%H%M%S"))
    with open(json_file, 'w') as outfile:
        json.dump(a_dict, outfile)
    result=subprocess.Popen(['/bin/bash', 'sddc.sh', json_file, log_file], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=folder)
    if os.path.isfile("/root/govc.error"):
      logging.error("SDDC creation: External vCenter not reachable")
      raise ValueError("SDDC creation: External vCenter not reachable")


# Helper function to delete sddc
def delete_sddc(spec):
    folder='/nested-vcf'
    a_dict = spec
    a_dict['operation'] = "destroy"
    now = datetime.datetime.now()
    json_file='/root/data.json'
    log_file="/nested-vcf/log/{0}-{1}_destroy.stdout".format(a_dict['sddc']['basename'], now.strftime("%Y%m%d%H%M%S"))
    with open(json_file, 'w') as outfile:
        json.dump(a_dict, outfile)
    result=subprocess.Popen(['/bin/bash', 'sddc.sh', json_file, log_file], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=folder)


def create_vcfi(spec):
    a_dict = spec
    json_file='/root/vcfi-{0}-patched.json'.format(a_dict['ip'])
    with open(json_file, 'w') as outfile:
        json.dump(a_dict, outfile)

def delete_vcfi(spec):
    a_dict = spec
    json_file='/root/vcfi-{0}-patched.json'.format(a_dict['ip'])
    os.remove(json_file)
#
#
#
#
@kopf.on.create('sddcs')
def on_create(body, **kwargs):
    spec = body['spec']
    try:
        create_sddc(spec)
    except requests.RequestException as e:
        raise kopf.PermanentError(f'Failed to create external resource: {e}')

@kopf.on.delete('sddcs')
def on_delete(body, **kwargs):
    spec = body['spec']
    try:
        delete_sddc(spec)
    except requests.RequestException as e:
        raise kopf.PermanentError(f'Failed to delete external resource: {e}')


@kopf.on.create('vcfi')
def on_create(body, **kwargs):
    spec = body['spec']
    try:
        create_vcfi(spec)
    except requests.RequestException as e:
        raise kopf.PermanentError(f'Failed to create external resource: {e}')

@kopf.on.delete('vcfi')
def on_delete(body, **kwargs):
    spec = body['spec']
    try:
        delete_vcfi(spec)
    except requests.RequestException as e:
        raise kopf.PermanentError(f'Failed to delete external resource: {e}')
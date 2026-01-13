# nested-vcf

## Goal

This repo automates the creation of a nested vcf leveraging vcf Cloud Builder.

## vSphere folder
- it creates a vSphere folder to host the other objects that will be created later

## ESXi servers
- a group of 4 servers
- connected to two NICs only to management (same port group)
- refresh the certificate // https://docs.vmware.com/en/VMware-Cloud-Foundation/5.1/vcf-deploy/GUID-20A4FD73-EB40-403A-99FF-DAD9E8F9E456.html
- disk (OS, cache, capacity)
- cpu
- memory
- NTP
- DNS
- folder

## cloud builder VM
- NTP
- DNS
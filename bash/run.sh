
# deletion
k delete -f 08_sddc.yaml
k delete -f 07_cloud_builder.yaml
k delete -f 06_esxi.yaml
k delete -f 05_folder.yaml
kubectl delete -f 03-operator.yaml --grace-period=0
k delete -f 02-variables.yaml
k delete -f 01-prereqs.yaml

# creation
k apply -f 01-prereqs.yaml
k apply -f 02-variables.yaml
kubectl apply -f 03-operator.yaml
k apply -f 05_folder.yaml
k apply -f 06_esxi.yaml
k apply -f 07_cloud_builder.yaml
k apply -f 08_sddc.yaml


kubectl delete -f 03-operator.yaml --grace-period=0 ; kubectl apply -f 03-operator.yaml

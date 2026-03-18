# Testing Freeze/Unfreeze in Lab

Before deploying to production, validate that `unfreezeTimeoutSeconds` works correctly in your environment.

**Requirement**: Guest Agent must be installed and running.

```bash
oc describe vmi <vm-centos> -n <namespace> | grep -i agent
    Type:                  AgentConnected
    Info Source:     domain, guest-agent
```

## Test 1: Validate Auto-Unfreeze

This is the **critical test**. Freeze the VM, do NOT unfreeze manually, and confirm it unfreezes by itself.

**Note**: Don't forget to update the 03-policy-reconcile.yaml file with the namespaces of your VMs.

```bash
VM=<vm-name>
NS=<namespace>
POD=$(oc get pod -n $NS -l vm.kubevirt.io/name=$VM \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

# Freeze with a short auto-unfreeze timeout (60s for testing)
oc exec -n $NS $POD -c compute -- \
  /usr/bin/virt-freezer --freeze --name $VM --namespace $NS \
  --unfreezeTimeoutSeconds 60

# Wait until it thaws
watch -d "oc describe vmi $VM -n $NS | grep -i freeze"

# Freeze without timeout
oc exec -n $NS $POD -c compute -- \
  /usr/bin/virt-freezer --freeze --name $VM --namespace $NS

# Confirm it's frozen
oc describe vmi $VM -n $NS | grep -i freeze
# Expected: Fs Freeze Status: frozen

# Check if the hooks have been updated.
# It may take a few minutes for the reconciler to take effect.
# To speed up the process, restart the VM.

while true
  do
    oc get pods -n $NS -l kubevirt.io=virt-launcher   -o json | jq '.items[] | {
      name: .metadata.name,
      pre_hook: .metadata.annotations["pre.hook.backup.velero.io/command"],
      timeout: .metadata.annotations["pre.hook.backup.velero.io/timeout"],
      on_error: .metadata.annotations["pre.hook.backup.velero.io/on-error"]
    }'
  sleep 10
  clear
done

# DO NOT unfreeze. Just wait for timeout.

# Confirm it unfroze by itself
watch -d "oc describe vmi $VM -n $NS | grep -i freeze"
# Expected: Fs Freeze Status empty or absent
```

**WARNING**: If the status is still `frozen` after timeout, the auto-unfreeze is not working and you should investigate with the community before relying on this workaround.


## Test 2: Validate Manual Freeze/Unfreeze Cycle

Basic sanity check that the QEMU Guest Agent is working:

```bash
# Freeze
oc exec -n $NS $POD -c compute -- \
  /usr/bin/virt-freezer --freeze --name $VM --namespace $NS \
  --unfreezeTimeoutSeconds 60

# Confirm frozen
oc describe vmi $VM -n $NS | grep -i freeze

# Wait 10 seconds (simulate snapshot window)
sleep 10

# Unfreeze
oc exec -n $NS $POD -c compute -- \
  /usr/bin/virt-freezer --unfreeze --name $VM --namespace $NS

# Confirm unfrozen
oc describe vmi $VM -n $NS | grep -i freeze
```


## Test 3: Simulate Storage Failure (advanced)

Force an I/O error on the VM's block device to test `errorPolicy`:

```bash
NODE=$(oc get vmi $VM -n $NS -o jsonpath='{.status.nodeName}')

# Find the device mapper device
oc debug node/$NODE -- chroot /host bash -c "
  POD_UID=<pod-uid>
  for DEV in /var/lib/kubelet/pods/\$POD_UID/volumeDevices/kubernetes.io~csi/*; do
    echo \"\$DEV -> \$(readlink -f \$DEV)\"
  done
"

# Inject I/O errors (replace dm-XX with actual device)
oc debug node/$NODE -- chroot /host bash -c "
  SECTORS=\$(blockdev --getsz /dev/dm-XX)
  dmsetup table dm-XX > /tmp/dm-XX-original.table
  dmsetup load dm-XX --table \"0 \$SECTORS error\"
  dmsetup resume dm-XX
"

# With errorPolicy: stop (default) -> VM will pause
# With errorPolicy: report -> VM stays running, Windows handles the error

# Restore
oc debug node/$NODE -- chroot /host bash -c "
  dmsetup load dm-XX --table \"\$(cat /tmp/dm-XX-original.table)\"
  dmsetup resume dm-XX
"
```

**WARNING**: Only do this on disposable test VMs. Never in production.

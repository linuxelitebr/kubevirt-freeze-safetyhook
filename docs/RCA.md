# Root Cause Analysis

## Incidents

Two separate incidents caused BSODs on Windows VMs running on OpenShift Virtualization.

## Summary

The backup tool uses Velero pre/post hook annotations on virt-launcher pods to freeze and unfreeze VM filesystems via `virt-freezer` (QEMU Guest Agent / Windows VSS). When the backup fails mid-flow (after freeze, before unfreeze), the post-hook never executes and the VM stays frozen indefinitely.

## Timeline (Incident 2)

| Time (UTC) | Component | Event |
|---|---|---|
| 09:02 | Backup tool | Backup fails with Error Code 10020 (PVC JSON not found) |
| 09:02 | Backup tool | 3 datamover pods fail consecutively for same PVC |
| 09:10 | virt-handler | DeadlineExceeded on GetDomainStats (VM unresponsive at libvirt level) |
| ~09:10-12:36 | VMs | Frozen for approximately 3.5 hours |
| 12:36 | virt-controller | Force stop VM, cascade of API server contention errors |
| 12:40-12:50 | KubeVirt | VMs restarted |

## Key Evidence

1. **DeadlineExceeded**: virt-handler couldn't even scrape metrics from the VM, confirming it was completely unresponsive at the hypervisor level

2. **Backup Error**: Backup failed because PVC JSON was missing from staging directory. The freeze had already been executed before this failure.

3. **Auto-unfreeze didn't trigger**: KubeVirt's built-in 5-minute `unfreezeTimeoutSeconds` did not activate, likely because the freeze was invoked via virt-freezer CLI (Velero hook) rather than via KubeVirt REST API

4. **Sequential restarts**: VMs were restarted in sequence with 7-8 minute intervals, consistent with the backup processing VMs sequentially

5. **No I/O tuning**: VMs had no `ioThreadsPolicy`, `blockMultiQueue`, or `errorPolicy` configured

## Contributing Factors

- Pre-hook timeout of only 60 seconds
- No `on-error` policy configured (defaults to Fail)
- `--unfreezeTimeoutSeconds` not included in the freeze command
- No fallback mechanism when backup aborts after freeze
- KubeVirt auto-injects hooks on every pod that has a connected QEMU Guest Agent

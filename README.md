# kubevirt-freeze-safetyhook

A workaround to prevent Windows VM BSODs caused by indefinite filesystem freeze during backup operations on OpenShift Virtualization.


## The Problem

When backup solutions use Velero hooks to freeze/unfreeze VM filesystems via `virt-freezer`, a failed backup can leave the VM frozen indefinitely, causing a Blue Screen of Death (BSOD) on Windows guests.

Here's how things go sideways:

```
1. Pre-hook:  virt-freezer --freeze    (freezes the VM filesystem)
2. Snapshot:  CSI snapshot             (creates the storage snapshot)
3. Datamover: copies data out          (can fail here)
4. Post-hook: virt-freezer --unfreeze  (unfreezes the VM filesystem)
```

If step 3 fails, step 4 never runs. The VM stays frozen. Windows accumulates I/O for hours, and eventually: BSOD.

In our case, VMs stayed frozen for **3.5 hours** before being forcefully restarted. KubeVirt's built-in auto-unfreeze (5-minute default) did not trigger because the freeze was invoked via CLI through Velero hook annotations, not through the KubeVirt REST API.


## The Solution

A set of tools (CronJob or Kyverno policy) that replace the original freeze/unfreeze hook annotations on virt-launcher pods with safety-net versions that guarantee automatic unfreeze.

The safety-net adds 3 layers of protection:

1. **`--unfreezeTimeoutSeconds 120`**: KubeVirt auto-unfreezes after 2 minutes, even if the post-hook never runs
2. **`timeout 45`**: If the freeze command itself hangs (guest agent unresponsive), it gets killed and unfreeze runs immediately
3. **`exit 0` + `on-error: Continue`**: Backup continues crash-consistent if anything fails, instead of aborting with the VM frozen

**When everything works fine**, the safety-net is transparent. The freeze runs, the snapshot completes, the post-hook unfreezes normally. No difference.

**When the backup fails**, the VM unfreezes itself in at most 2 minutes instead of staying frozen for hours. The backup fails, but the VM stays operational. You retry the backup on the next window instead of dealing with a BSOD.

### Before vs After

```
Before (original hook):
  /usr/bin/virt-freezer --freeze --name <vm> --namespace <ns>

After (safety-net hook):
  timeout 45 /usr/bin/virt-freezer --freeze --name <vm> --namespace <ns>
    --unfreezeTimeoutSeconds 120
    || /usr/bin/virt-freezer --unfreeze --name <vm> --namespace <ns>;
  exit 0
```


## Important Disclaimers

**This is NOT a silver bullet.** This is a workaround while we wait for the backup vendor to provide a proper fix. The root cause is that the backup tool does not guarantee unfreeze execution when the datamover fails after the freeze has been applied.

**This has been tested** on OpenShift 4.19 with CNV 4.19.18 and KubeVirt v1.5.3. Your mileage may vary with different storage backends or OpenShift versions.

**The `unfreezeTimeoutSeconds` value (120s)** should be tuned based on how long your CSI snapshots take. In our environment, storage snapshots complete in under 10 seconds, so 120s gives plenty of margin. If your snapshots are slower, increase accordingly.

**In a failure scenario**, the backup may result in crash-consistent instead of application-consistent. This is a deliberate tradeoff: a crash-consistent backup that you can retry is better than a VM with BSOD.

**This is an unofficial, unsupported workaround.** It is not endorsed by Red Hat, and Kyverno is not part of the OpenShift supported ecosystem. The underlying problem is not caused by OpenShift or KubeVirt, but by the backup tool's failure to guarantee unfreeze execution when its own workflow fails. This workaround exists solely because the fix depends on a third-party vendor. If you open a support case with Red Hat, be transparent about this workaround being in place, and be prepared to remove it if asked to reproduce the issue in a clean state.


## Deployment Options

### Option 1: CronJob (recommended for supportability)

Uses only native Kubernetes resources. No third-party components, no admission webhooks, no impact on Red Hat support. Runs every 5 minutes and patches annotations on existing pods.

The small delay (up to 5 minutes) is acceptable because backups run on a schedule, and the CronJob will have corrected the annotations before the backup starts.

See [cronjob/](cronjob/) for installation instructions.

### Option 2: Kyverno

Intercepts pod creation in real-time. No delay, no window of exposure. Works on both standalone OpenShift clusters and HyperShift (with custom TLS certificates).

The policies use a `namespaceSelector`, so you control which namespaces are protected by labeling them:

```bash
oc label namespace my-database-ns backup-safetyhook=enabled
oc label namespace my-workload-ns backup-safetyhook=enabled
```

No need to edit the policies when adding or removing namespaces.

See [kyverno/](kyverno/) for installation instructions.

**WARNING**: Please be aware that Kyverno may affect the normal operation of OpenShift, causing unintended consequences.


## Additional Resources

- [docs/RCA.md](docs/RCA.md) - Root Cause Analysis of the original incidents
- [tuning/](tuning/) - I/O tuning recommendations for Windows VMs on OpenShift Virtualization
- [docs/freeze-test.md](docs/freeze-test.md) - How to test freeze/unfreeze in a lab environment


## Tested Environment

| Component | Version |
|---|---|
| OpenShift | 4.19 (Kubernetes v1.32) |
| OpenShift Virtualization (CNV) | 4.19.18 |
| KubeVirt | v1.5.3 |
| Kyverno | 3.2.7 / 1.17.1 |
| Guest OS | Windows Server (NTFS) |


## Contributing

Found a bug? Have a better approach? PRs welcome. This is a community workaround born from production incidents, not a polished product. If you've hit the same problem with a different backup tool or storage backend, your experience would be valuable here.

## License

MIT

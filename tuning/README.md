# I/O Tuning for Windows VMs on OpenShift Virtualization

These are independent of the freeze/unfreeze workaround but improve VM performance and resilience.

## High I/O Profile

For VMs with heavy parallel read/write patterns (file servers, batch processing, scanning workloads).

```yaml
spec:
  template:
    spec:
      domain:
        ioThreadsPolicy: auto
        devices:
          blockMultiQueue: true
          autoattachMemBalloon: false
          disks:
          - disk:
              bus: virtio
            name: os-disk
            errorPolicy: report
            blockSize:
              matchVolume:
                enabled: true
          - disk:
              bus: virtio
            name: data-disk
            errorPolicy: report
            blockSize:
              matchVolume:
                enabled: true
        features:
          hyperv:
            relaxed: { enabled: true }
            vapic: { enabled: true }
            spinlocks: { enabled: true, spinlocks: 8191 }
            vpindex: { enabled: true }
            synic: { enabled: true }
            reset: { enabled: true }
```

## Database Profile (SQL Server)

For VMs with mixed read/write and low-latency requirements.

```yaml
spec:
  template:
    spec:
      domain:
        cpu:
          dedicatedCpuPlacement: true
          isolateEmulatorThread: true
        ioThreadsPolicy: auto
        memory:
          hugepages:
            pageSize: "2Mi"
        devices:
          blockMultiQueue: true
          autoattachMemBalloon: false
          disks:
          - disk:
              bus: virtio
            name: os-disk
          - disk:
              bus: virtio
            name: sql-data
            dedicatedIOThread: true
            errorPolicy: report
            blockSize:
              matchVolume:
                enabled: true
          - disk:
              bus: virtio
            name: sql-log
            dedicatedIOThread: true
        features:
          hyperv:
            relaxed: { enabled: true }
            vapic: { enabled: true }
            spinlocks: { enabled: true, spinlocks: 8191 }
            vpindex: { enabled: true }
            synic: { enabled: true }
            synictimer: { enabled: true }
            frequencies: { enabled: true }
            tlbflush: { enabled: true }
            ipi: { enabled: true }
            reset: { enabled: true }
```

## What Each Setting Does

| Setting | Effect |
|---|---|
| `ioThreadsPolicy: auto` | Creates dedicated threads for disk I/O, proportional to vCPUs |
| `blockMultiQueue: true` | One I/O queue per vCPU instead of a single shared queue |
| `dedicatedIOThread: true` | Exclusive I/O thread for that specific disk |
| `autoattachMemBalloon: false` | Disables memory ballooning (causes unpredictable latency) |
| `errorPolicy: report` | Reports I/O errors to guest OS instead of pausing the VM |
| `blockSize.matchVolume` | Aligns virtual block size with physical storage |
| `hyperv.*` | Windows paravirtualization optimizations |
| `dedicatedCpuPlacement` | Pins vCPUs to physical cores (reduces jitter) |
| `isolateEmulatorThread` | Dedicated core for QEMU emulator and I/O threads |
| `hugepages` | Reduces TLB misses for memory-intensive workloads |

## Applying

```bash
# Check disk names first
oc get vm <vm-name> -n <namespace> \
  -o jsonpath='{range .spec.template.spec.domain.devices.disks[*]}{.name}{"\n"}{end}'

# Patch (adjust disk names to match)
oc patch vm <vm-name> -n <namespace> --type merge -p '<yaml-above>'

# Restart to apply
virtctl restart <vm-name> -n <namespace>
```

## Monitoring After Applying

```bash
# Confirm settings took effect
oc get vmi <vm-name> -n <namespace> -o yaml | grep -E "ioThread|blockMulti|errorPolicy"

# Monitor node CPU (IOThreads add overhead)
oc adm top node <node-name>
```

Recommendation: apply `blockMultiQueue` first (low risk), then `ioThreadsPolicy` in a second maintenance window with CPU monitoring.

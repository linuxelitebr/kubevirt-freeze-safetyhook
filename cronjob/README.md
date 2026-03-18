# CronJob Deployment

A lightweight alternative to Kyverno that uses only native Kubernetes resources. Better for environments where supportability matters (no third-party admission webhooks in the cluster).

## How It Works

A CronJob runs every 5 minutes, auto-discovers all namespaces with virt-launcher pods, and replaces the original freeze hooks with safety-net versions. Uses standard `oc annotate` commands, nothing exotic.

## Trade-offs vs Kyverno

| | Kyverno | CronJob |
|---|---|---|
| When it acts | Instantly (at pod creation) | Up to 5 min delay |
| Dependencies | Kyverno (third-party webhook) | None (native K8s) |
| Red Hat support impact | May be asked to remove for troubleshooting | No impact |
| Complexity | Higher (webhook, TLS, SCC) | Lower |
| HyperShift | Requires custom TLS certs + specific version | Works out of the box |
| Namespace management | Label namespaces to include | Auto-discovery, label to exclude |

The 5-minute delay is acceptable in practice because backups typically run on a schedule (e.g., nightly). The CronJob will have corrected the annotations long before the backup starts.

## Understanding the Timeouts

The safety-net uses 3 different timeouts, each with a different purpose. They work as layers, from inner to outer:

```
timeout 45s  (kills the freeze command if the guest agent hangs)
  < unfreezeTimeoutSeconds 120s  (KubeVirt auto-unfreezes if post-hook never runs)
    < velero timeout 180s  (max time Velero waits for the hook to return)
```

**`timeout 45`** (FREEZE_TIMEOUT, inside the command): If the `virt-freezer --freeze` command hangs (guest agent unresponsive), the Linux `timeout` utility kills the process after 45 seconds. The `||` fallback then runs unfreeze immediately. Protects against a stuck freeze command.

**`--unfreezeTimeoutSeconds 120`** (UNFREEZE_TIMEOUT, virt-freezer parameter): Tells the virt-launcher to schedule an automatic unfreeze after 120 seconds, even if no one calls unfreeze explicitly. This is the main safety-net. If the backup fails and the post-hook never executes, the VM unfreezes itself. Protects against missing post-hook.

**`pre.hook.backup.velero.io/timeout=180s`** (Velero annotation): How long Velero waits for the pre-hook command to return before treating it as an error. The default is 60 seconds, which is too short for VMs with heavy I/O. 180 seconds gives enough room for the freeze to complete even under load. Must be larger than the other two timeouts, otherwise Velero kills the hook before the internal safety-net can act.

**`pre.hook.backup.velero.io/on-error=Continue`** (Velero annotation): If the hook fails for any reason, Velero continues with the backup (crash-consistent) instead of aborting. Without this, a failed hook can leave the VM frozen with no backup and no unfreeze.

## Auto-Discovery

The CronJob automatically finds all namespaces that have virt-launcher pods. No configuration needed. When a new namespace with VMs is created, the CronJob picks it up on the next run.

No ConfigMap, no static list, no manual maintenance.

## Filtering by Namespace Label

For environments where namespaces with VMs use a specific label (e.g., `ambiente=virtualizacao`), you can configure the CronJob to only target those namespaces instead of auto-discovering all.

Edit the `NS_LABEL_SELECTOR` environment variable in the CronJob YAML:

```yaml
env:
- name: NS_LABEL_SELECTOR
  # Leave empty for auto-discovery (default).
  # Set to filter by label, e.g.: "ambiente=virtualizacao"
  value: "ambiente=virtualizacao"
```

When set, the CronJob only processes namespaces that have that label. When empty (default), it discovers all namespaces with virt-launcher pods automatically.

The exclusion label (`backup-safetyhook-exclude=true`) still works on top of the label selector, so you can combine both.

## Excluding Namespaces

By default, the CronJob protects all discovered namespaces. To exclude a specific namespace (e.g., a lab namespace where you want original hooks):

```bash
oc label namespace my-lab-ns backup-safetyhook-exclude=true
```

The CronJob will skip that namespace on the next run. Pods that already have the safety-net keep it until the VM restarts. On restart, the virt-controller recreates the pod with original hooks, and the CronJob won't touch it again.

To re-include a namespace:

```bash
oc label namespace my-lab-ns backup-safetyhook-exclude-
```

## Install

```bash
oc apply -f safetyhook-all-in-one.yaml
```

Expected job log output:

```text
=== Safety-net hook manager ===
Started: Fri Mar 14 18:00:00 UTC 2026
Mode: auto-discovery (all namespaces with VMs)

Discovered namespaces: my-database-ns my-workload-ns

=== Processing namespace: my-database-ns ===
  Applying safety-net: virt-launcher-myvm-abc12 (VM: myvm)
  OK: virt-launcher-myvm-abc12

=== Processing namespace: my-workload-ns ===
  Already protected: virt-launcher-othervm-def34

=== Completed: Fri Mar 14 18:00:03 UTC 2026
```

## Verify a specific namespace

```bash
oc get pods -n <namespace> -l kubevirt.io=virt-launcher \
  -o json | jq '.items[] | {
    name: .metadata.name,
    timeout: .metadata.annotations["pre.hook.backup.velero.io/timeout"],
    on_error: .metadata.annotations["pre.hook.backup.velero.io/on-error"],
    has_safetyhook: (.metadata.annotations["pre.hook.backup.velero.io/command"]
      | contains("unfreezeTimeoutSeconds") // false)
  }'
```

## Verify all namespaces

```bash
while true; do
  oc get pods --all-namespaces -l kubevirt.io=virt-launcher \
    --field-selector=status.phase=Running \
    -o json | jq '.items[] | {
      namespace: .metadata.namespace,
      vm: .metadata.labels["vm.kubevirt.io/name"],
      timeout: .metadata.annotations["pre.hook.backup.velero.io/timeout"],
      on_error: .metadata.annotations["pre.hook.backup.velero.io/on-error"],
      safetyhook: (.metadata.annotations["pre.hook.backup.velero.io/command"]
        | if . then contains("unfreezeTimeoutSeconds") else false end)
    }'
  sleep 10
  clear
done
```

Expected output:

```json
{
  "namespace": "rta-test-01",
  "vm": "fedora-copper-baboon-44",
  "timeout": "180s",
  "on_error": "Continue",
  "safetyhook": true
}
{
  "namespace": "rta-test-01",
  "vm": "rhel8-gray-jay-90",
  "timeout": "180s",
  "on_error": "Continue",
  "safetyhook": true
}
{
  "namespace": "rta-test-02",
  "vm": "centos-stream9-yellow-grasshopper-70",
  "timeout": "180s",
  "on_error": "Continue",
  "safetyhook": true
}
{
  "namespace": "rta-test-02",
  "vm": "rhel9-beige-mockingbird-58",
  "timeout": "180s",
  "on_error": "Continue",
  "safetyhook": true
}
```

## Adjust Schedule

Default is every 5 minutes. To change, edit `spec.schedule` in the CronJob YAML:

```yaml
# Every 2 minutes (more aggressive)
schedule: "*/2 * * * *"

# Every minute (minimum recommended)
schedule: "* * * * *"
```

## Adjust Timeouts

Edit the environment variables in the CronJob YAML:

```yaml
env:
- name: UNFREEZE_TIMEOUT
  value: "120"          # seconds for auto-unfreeze (default: 120)
- name: FREEZE_TIMEOUT
  value: "45"           # seconds before freeze command is killed (default: 45)
```

The hierarchy MUST be maintained:

```
FREEZE_TIMEOUT (45) < UNFREEZE_TIMEOUT (120) < velero timeout (180)
```

If you change one, adjust the others to keep the order. The Velero timeout (180s) is set in the annotation and must always be the largest.

## Uninstall

```bash
oc delete -f safetyhook-all-in-one.yaml
```

Hook annotations will revert to originals on next VM restart.
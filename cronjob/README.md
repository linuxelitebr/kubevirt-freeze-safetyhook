# CronJob Deployment

A lightweight alternative to Kyverno that uses only native Kubernetes resources. Better for environments where supportability matters (no third-party admission webhooks in the cluster).

## How It Works

Two CronJobs work together:

**safetyhook-db** (every 5 minutes, namespace `openshift-cnv`): Auto-discovers namespaces with VMs and replaces original freeze hooks with safety-net versions using standard `oc annotate` commands.

**safetyhook-monitor** (every 2 minutes, namespace `safetyhook-monitor`): Checks the `fsFreezeStatus` of all VMIs and logs only state **transitions** (FROZEN, RECOVERED). Uses a ConfigMap to track previous state. Produces zero logs when all VMs are healthy. The monitor runs in a dedicated namespace because logs from `openshift-*` namespaces go to the infrastructure tenant, which may not be collected or indexed the same way.

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
  < KubeVirt auto-unfreeze 5m  (internal default, see note below)
    < velero timeout 180s  (max time Velero waits for the hook to return)
```

**`timeout 45`** (FREEZE_TIMEOUT, inside the command): If the `virt-freezer --freeze` command hangs (guest agent unresponsive), the Linux `timeout` utility kills the process after 45 seconds. The `||` fallback then runs unfreeze immediately. Protects against a stuck freeze command.

**`--unfreezeTimeoutSeconds 120`** (UNFREEZE_TIMEOUT, virt-freezer parameter): Tells the virt-launcher to schedule an automatic unfreeze. However, during testing we confirmed that this parameter is **not honored when invoked via CLI**. KubeVirt falls back to the internal default of **5 minutes** regardless of the value passed. The parameter only works via the KubeVirt REST API. The safety-net still works: the VM unfreezes after 5 minutes instead of staying frozen indefinitely.

**`pre.hook.backup.velero.io/timeout=180s`** (Velero annotation): How long Velero waits for the pre-hook command to return before treating it as an error. The default is 60 seconds, which is too short for VMs with heavy I/O. 180 seconds gives enough room for the freeze to complete even under load.

**`pre.hook.backup.velero.io/on-error=Continue`** (Velero annotation): If the hook fails for any reason, Velero continues with the backup (crash-consistent) instead of aborting. Without this, a failed hook can leave the VM frozen with no backup and no unfreeze.

## Logging and Detection

### How the monitor works

The monitor CronJob checks the actual `fsFreezeStatus` of every VMI via the Kubernetes API. It uses a ConfigMap (`freeze-state`) to remember which VMs were frozen in the previous execution. By comparing current state against previous state, it detects transitions and only logs when something changes:

| Previous state | Current state | Action |
|---|---|---|
| unfrozen | unfrozen | no log |
| unfrozen | frozen | logs `FROZEN` |
| frozen | frozen | no log (already reported) |
| frozen | unfrozen | logs `RECOVERED` |

This means: zero logs when everything is healthy, even with a thousand VMs.

### Log markers

| Marker | When it appears | Meaning |
|---|---|---|
| `SAFETYHOOK-MONITOR: FROZEN` | VM just entered frozen state | A backup freeze is active or something went wrong |
| `SAFETYHOOK-MONITOR: RECOVERED` | VM just returned to normal | The auto-unfreeze mechanism worked, VM is safe |
| `SAFETYHOOK-EMERGENCY` | Pre-hook fallback branch (via `oc logs`) | Freeze command failed or timed out, fallback unfreeze forced |
| `SAFETYHOOK: post-hook unfreeze` | Post-hook (via `oc logs`) | Normal unfreeze, backup flow completed |

### How to detect each scenario

| Scenario | What happened | How to detect | Severity |
|---|---|---|---|
| Normal flow | Freeze ok, backup ok, post-hook unfreeze | No monitor log (too fast to catch) | Info |
| VM frozen | VM entered frozen state | `SAFETYHOOK-MONITOR: FROZEN` in Loki | Critical |
| Auto-unfreeze worked | VM recovered from frozen state | `SAFETYHOOK-MONITOR: RECOVERED` in Loki | Warning |
| Freeze failed or timed out | Guest agent hung, fallback unfreeze ran | `SAFETYHOOK-EMERGENCY` via `oc logs` on virt-launcher | Critical |

### Loki queries (Observe > Logs, tenant Application)

All monitor events (frozen and recovered):

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR"
```

Only frozen VMs:

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR: FROZEN"
```

Only recovered VMs (auto-unfreeze worked):

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR: RECOVERED"
```

Filter by specific VM:

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR" |= "vm=win2k19"
```

Filter by specific namespace:

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR" |= "namespace=my-database-ns"
```

### CLI verification (alternative to Loki)

```bash
# Latest monitor run
oc logs -n safetyhook-monitor -l job-name --tail=20

# Check all VMI freeze status directly
oc get vmi --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.fsFreezeStatus // "unfrozen")"'

# Check ConfigMap (current frozen list)
oc get configmap freeze-state -n safetyhook-monitor -o jsonpath='{.data.frozen-vms}'

# Watch in real time
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

## Auto-Discovery

The CronJob automatically finds all namespaces that have virt-launcher pods. No configuration needed. When a new namespace with VMs is created, the CronJob picks it up on the next run.

No ConfigMap, no static list, no manual maintenance.

## Filtering by Namespace Label

For environments where namespaces with VMs use a specific label (e.g., `ambiente=virtualizacao`), you can configure the CronJobs to only target those namespaces instead of auto-discovering all.

Edit the `NS_LABEL_SELECTOR` environment variable in both CronJobs (safetyhook-db and safetyhook-monitor):

```yaml
env:
- name: NS_LABEL_SELECTOR
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

This creates all resources in a single command: namespace `safetyhook-monitor`, ServiceAccounts, ClusterRoles, ClusterRoleBindings, SCC binding, ConfigMap, and both CronJobs.

For Loki alerting, also label the monitor namespace:

```bash
oc label namespace safetyhook-monitor openshift.io/cluster-monitoring=true
```

## Test the safety-net

```bash
oc create job --from=cronjob/safetyhook-db test-safetyhook -n openshift-cnv
oc logs -n openshift-cnv job/test-safetyhook -f
oc delete job test-safetyhook -n openshift-cnv
```

Expected output:

```text
=== Safety-net hook manager ===
Started: Fri Mar 14 18:00:00 UTC 2026
Mode: auto-discovery (all namespaces with VMs)

Discovered namespaces: my-database-ns my-workload-ns

=== Processing namespace: my-database-ns ===
  Applying safety-net: virt-launcher-myvm-abc12 (VM: myvm)
  OK: virt-launcher-myvm-abc12

=== Completed: Fri Mar 14 18:00:03 UTC 2026
```

## Test the monitor

**Step 1: Run with all VMs healthy (expect zero logs)**

```bash
oc create job --from=cronjob/safetyhook-monitor test1 -n safetyhook-monitor
oc logs -n safetyhook-monitor job/test1 -f
oc delete job test1 -n safetyhook-monitor
```

**Step 2: Freeze a VM**

```bash
POD=$(oc get pod -n <namespace> -l vm.kubevirt.io/name=<vm-name> -o jsonpath='{.items[0].metadata.name}')
oc exec -n <namespace> ${POD} -c compute -- \
  /usr/bin/virt-freezer --freeze --name <vm-name> --namespace <namespace>
```

**Step 3: Run monitor (expect FROZEN)**

```bash
oc create job --from=cronjob/safetyhook-monitor test2 -n safetyhook-monitor
oc logs -n safetyhook-monitor job/test2 -f
oc delete job test2 -n safetyhook-monitor
```

Expected: `SAFETYHOOK-MONITOR: FROZEN vm=<vm-name> namespace=<namespace> ...`

**Step 4: Wait ~5 minutes (KubeVirt auto-unfreeze), run monitor (expect RECOVERED)**

```bash
oc create job --from=cronjob/safetyhook-monitor test3 -n safetyhook-monitor
oc logs -n safetyhook-monitor job/test3 -f
oc delete job test3 -n safetyhook-monitor
```

Expected: `SAFETYHOOK-MONITOR: RECOVERED vm=<vm-name> namespace=<namespace> ...`

**Step 5: Verify in Loki (Observe > Logs, tenant Application)**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR"
```

## Verify safety-net annotations (specific namespace)

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

## Adjust Schedule

Default is every 5 minutes for the safety-net and every 1 minute for the monitor. To change, edit `spec.schedule` in the CronJob YAML:

```yaml
# Safety-net: every 2 minutes (more aggressive)
schedule: "*/2 * * * *"

# Monitor: every 3 minutes (less API calls, still detects within cycle)
schedule: "*/3 * * * *"

# Monitor: every 4 minutes (good balance for large clusters)
schedule: "*/4 * * * *"
```

For large clusters (5000+ VMs), running the monitor every 2 or 3 minutes is recommended to reduce API load while still detecting freeze events before the 5-minute auto-unfreeze kicks in.

## Adjust Timeouts

Edit the environment variables in the safety-net CronJob:

```yaml
env:
- name: UNFREEZE_TIMEOUT
  value: "120"          # passed to virt-freezer (see note about CLI limitation)
- name: FREEZE_TIMEOUT
  value: "45"           # seconds before freeze command is killed
```

Note: the `UNFREEZE_TIMEOUT` value is passed to `virt-freezer` but is not honored via CLI invocation. The actual auto-unfreeze timeout is the KubeVirt internal default of 5 minutes. We keep the parameter in the command for forward compatibility in case a future KubeVirt version fixes this behavior.

## Uninstall

```bash
oc delete -f safetyhook-all-in-one.yaml
```

Hook annotations will revert to originals on next VM restart.
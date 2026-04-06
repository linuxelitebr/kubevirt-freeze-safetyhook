# Hitachi VSP / NetBackup Alerts: OpenShift + Loki

Alerting stack for Hitachi VSP snapshot failures and NetBackup freeze-related incidents on OpenShift Virtualization clusters.

## Files

| File | Purpose |
|---|---|
| `01-alertingrule-hitachi-backup-alerts.yaml` | Defines LogQL-based alerts via Loki Ruler |
| `02-alertmanagerconfig-backup-storage-routing.yaml` | Routes and delivers alert notifications |

> **Note:** The correct CRD for LogQL-based alerts is `AlertingRule` (`loki.grafana.com/v1`), not `PrometheusRule`. PrometheusRule only accepts PromQL and will reject LogQL expressions with a parse error on the `|` character.

## Alerts

| Alert | Severity | Fires when | `for` |
|---|---|---|---|
| `HitachiStorageError` | critical | Any VSP storage error in the last 5 min | immediate |
| `HitachiLDEVExhausted` | critical | LDEV ID exhaustion specifically (KART30000-E) | immediate |
| `NetBackupSnapshotTimeout` | critical | Backup controller timeout | 1 min |
| `VirtFreezerActiveWithoutUnfreeze` | warning | pre-hooks >> post-hooks for 5+ min | 5 min |
| `SafetyhookEmergencyUnfreeze` | critical | Safety-net fallback unfreeze triggered (freeze failed or timed out) | immediate |
| `SafetyhookVMFrozen` | critical | Monitor CronJob detected a VM in frozen state | 2 min |
| `SafetyhookVMRecovered` | warning | Monitor CronJob detected a VM recovered from frozen state | immediate |

Alerts 1 and 2 target the storage layer. Alert 1 is broader (any VSP error). Alert 2 is specific to LDEV exhaustion and useful for Zabbix correlation.

Alert 3 fires when a **backup** job has already **failed** and VMs may be **frozen**.

Alert 4 is the early warning. It fires *before* the timeout, giving the team time to act before a forced shutdown causes a BSOD (stop code 0x1A).

Alert 5 fires when the safety-net pre-hook fallback was activated. The freeze command failed or timed out (guest agent hung), and the `||` branch forced an immediate unfreeze. The VM is safe, but the freeze did not work as expected.

Alert 6 fires when the monitor CronJob detects a VM with `fsFreezeStatus=frozen`. This is the most reliable detection method because it reads the actual VMI state via the Kubernetes API, independent of what the virt-launcher or virt-handler log or fail to log.

Alert 7 fires when the monitor CronJob detects that a VM transitioned from frozen back to normal. This confirms the auto-unfreeze mechanism worked. The alert is informational but valuable for audit: it proves the safety-net protected the VM.

## Important Note on unfreezeTimeoutSeconds

During testing, we confirmed that the `unfreezeTimeoutSeconds` parameter passed via CLI (`virt-freezer --freeze --unfreezeTimeoutSeconds 120`) does **not** honor the specified value. KubeVirt falls back to the internal default of **5 minutes** regardless of the value passed. This appears to be a limitation where the parameter only works when invoked via the KubeVirt REST API, not via the CLI.

This means the actual timeout hierarchy in practice is:

```
timeout 45s  (kills the freeze command if the guest agent hangs)
  < KubeVirt auto-unfreeze 5m  (internal default, ignores CLI parameter)
    < velero timeout 180s  (max time Velero waits for the hook to return)
```

The safety-net still works: the VM unfreezes automatically after 5 minutes instead of staying frozen indefinitely. The monitor CronJob detects both the freeze and the recovery, logging them for alerting and audit.

## Prerequisites

### 1. Loki Ruler must be running

```bash
oc get pods -n openshift-logging | grep ruler
```

Should return at least one `Running` pod. If not, enable the Ruler in the LokiStack (see section below).

### 2. Alertmanager must be running

```bash
oc get pods -n openshift-monitoring | grep alertmanager
```

Alerts are sent by default to the Alertmanager in `openshift-monitoring`. No additional monitoring stack is required.

### 3. Logs must be reaching Loki

```bash
oc logs -n backup-netbackup deployment/backup-netbackup-controller-manager \
  --since=1h | grep "An error occurred in the storage system"
```

### 4. Safety-net monitor CronJob must be running

Alerts 6 and 7 depend on the monitor CronJob running in the `safetyhook-monitor` namespace. This CronJob checks `fsFreezeStatus` of all VMIs and logs state transitions (FROZEN, RECOVERED) that the Loki Ruler evaluates.

```bash
oc get cronjob safetyhook-monitor -n safetyhook-monitor
```

## LokiStack configuration (run once per cluster)

The LokiStack must have `rules` enabled with `selector` and `namespaceSelector` pointing to a label that will be applied to the AlertingRule and its namespace.

### Patch the LokiStack

```bash
oc patch lokistack logging-loki -n openshift-logging --type=merge -p '{
  "spec": {
    "rules": {
      "enabled": true,
      "selector": {
        "matchLabels": {"openshift.io/cluster-monitoring": "true"}
      },
      "namespaceSelector": {
        "matchLabels": {"openshift.io/cluster-monitoring": "true"}
      }
    }
  }
}'
```

### Label the application namespaces

```bash
oc label namespace backup-netbackup openshift.io/cluster-monitoring=true
oc label namespace safetyhook-monitor openshift.io/cluster-monitoring=true
```

> These steps are only needed if not already configured. Verify with:

> ```bash
> oc get lokistack logging-loki -n openshift-logging -o yaml | grep -A 10 "rules:"
> oc get namespace backup-netbackup --show-labels | grep cluster-monitoring
> oc get namespace safetyhook-monitor --show-labels | grep cluster-monitoring
> ```

## Apply

```bash
oc apply -f 01-alertingrule-hitachi-backup-alerts.yaml
oc apply -f 02-alertmanagerconfig-backup-storage-routing.yaml

# Verify
oc get alertingrule -n backup-netbackup
oc get alertmanagerconfig -n backup-netbackup
```

## Verifying the alerts are loaded

Loki AlertingRules are evaluated by the **Loki Ruler**, not by Prometheus.

Because of this, they do **not** appear under **Observe > Alerting > Alerting Rules** in the OpenShift console. That page only shows Prometheus-based rules.

Loki-based alerts only appear in **Observe > Alerting > Alerts** when they are actively **firing**. In normal conditions (no errors) they are invisible in the console, which is expected behavior.

To confirm the rules were loaded correctly, check the Ruler logs:

```bash
oc logs -n openshift-logging logging-loki-ruler-0 --since=5m \
  | grep -E "hitachi|backup|safetyhook|loaded|rules|updating"
```

A successful load shows:

```
msg="updating rule file" file=...backup-netbackup-hitachi-backup-alerts...
```

## Configure the notification receiver

Edit `02-alertmanagerconfig-backup-storage-routing.yaml` and fill in the notification channel your team uses:

**Email**: fill in `to`, `from`, `smarthost`
**Teams / generic webhook**: uncomment `webhookConfigs` and add the URL
**Slack**: uncomment `slackConfigs`
**PagerDuty**: uncomment `pagerdutyConfigs`

## Freeze State Monitoring

The safety-net includes a dedicated monitor CronJob (`safetyhook-monitor`) that runs in the `safetyhook-monitor` namespace. It checks the `fsFreezeStatus` field of every VMI in the cluster and logs only state **transitions**, not continuous status.

This approach was adopted because:
1. The native virt-launcher log messages (`initiating unfreeze`) were not reliably collected by the logging stack in all cluster configurations.
2. Logging every VM status every minute would generate excessive volume at scale (e.g., 7000+ VMs).

The monitor uses a ConfigMap (`freeze-state`) to track which VMs were frozen in the previous execution. It compares the current state against the previous state and only logs when something changes.

### Log markers

| Marker | When it appears | Meaning |
|---|---|---|
| `SAFETYHOOK-MONITOR: FROZEN` | VM just entered frozen state | A backup freeze is active or something went wrong |
| `SAFETYHOOK-MONITOR: RECOVERED` | VM just returned to normal | The auto-unfreeze mechanism worked, VM is safe |

In normal operation (all VMs healthy), the monitor produces **zero logs**.

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
# Find the job name for the monitor
oc get jobs -n safetyhook-monitor

# Latest monitor run - replace <job-name> with the value from the command above
oc logs -n safetyhook-monitor -l job-name=<job-name> --tail=20

# Alternatively, select all pods from any job in the namespace (no specific job-name needed)
oc logs -n safetyhook-monitor -l job-name --tail=20

# Follow logs in real time (useful during an active migration or snapshot window)
oc logs -n safetyhook-monitor -l job-name --tail=20 -f

# Filter output for errors or warnings only
oc logs -n safetyhook-monitor -l job-name --tail=100 | grep -iE "error|warn|fail|timeout"

# Check which pods are selected before reading logs
oc get pods -n safetyhook-monitor -l job-name

# The `-l job-name` option without a value is already sufficiently generic. It selects any pod created by any Job in the namespace, which is the expected behavior for a dynamically named monitor. The `oc get jobs` command is only useful for those who want to filter a specific run.

# Check all VMI freeze status directly
oc get vmi --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.fsFreezeStatus // "unfrozen")"'

# Check ConfigMap (current frozen list)
oc get configmap freeze-state -n safetyhook-monitor -o jsonpath='{.data.frozen-vms}'
```

## Troubleshooting

```bash
# Check if the Ruler loaded the rules
oc logs -n openshift-logging logging-loki-ruler-0 --since=5m \
  | grep -E "hitachi|backup|safetyhook|loaded|rules|updating"

# Check AlertingRule was accepted
oc get alertingrule -n backup-netbackup

# Force Alertmanager reload if needed
oc delete pod -n openshift-monitoring -l app.kubernetes.io/name=alertmanager
```

**Common issues:**

| Symptom | Cause | Fix |
|---|---|---|
| `parse error: unexpected character` | Wrong CRD (PrometheusRule instead of AlertingRule) | Use `kind: AlertingRule` with `apiVersion: loki.grafana.com/v1` |
| `spec.tenantID: Invalid value` | AlertingRule in wrong namespace | Move to `backup-netbackup` namespace |
| `spec.tenantID: Required value` | Missing `tenantID` field | Add `tenantID: "application"` under `spec` |
| Ruler logs show no trace of the rule | LokiStack rules.selector or namespace label missing | Apply LokiStack patch and label the namespace |
| Alerts not visible in Alerting Rules page | Expected for Loki rules | Check Alerts tab (only visible when firing) |
| `SAFETYHOOK-MONITOR` not in Loki | Monitor CronJob not running or namespace not labeled | Check CronJob in `safetyhook-monitor` ns, label ns with `openshift.io/cluster-monitoring=true` |
| Monitor runs but no FROZEN/RECOVERED logs | Expected when all VMs are healthy | Only state transitions produce logs |
| virt-launcher logs not in Loki | Known limitation in some cluster configurations | Use the monitor CronJob instead (already included in the all-in-one) |

## Testing: Simulating a failure

Since alerts from the Loki Ruler only appear in the OpenShift console (**Observe > Alerts**) when actively firing, you can simulate a failure by injecting log messages manually.

### Alert 1: HitachiStorageError / Alert 2: HitachiLDEVExhausted

```bash
oc run logger-test -n backup-netbackup \
  --image=busybox \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"logger-test","image":"busybox","args":["sh","-c","while true; do echo \"An error occurred in the storage system KART30000-E no available LDEV ID in the system or resource groups\"; sleep 1; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sh -c 'placeholder'
```

### Alert 3: NetBackupSnapshotTimeout

```bash
oc run logger-test-timeout -n backup-netbackup \
  --image=busybox \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"logger-test-timeout","image":"busybox","args":["sh","-c","while true; do echo \"timed out waiting for the condition\"; sleep 1; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sh -c 'placeholder'
```

### Alert 6: SafetyhookVMFrozen / Alert 7: SafetyhookVMRecovered

To test these alerts, freeze a real VM and wait for the monitor CronJob to detect the transitions:

```bash
POD=$(oc get pod -n default -l vm.kubevirt.io/name=<vm-name> -o jsonpath='{.items[0].metadata.name}')
oc exec -n default ${POD} -c compute -- \
  /usr/bin/virt-freezer --freeze --name <vm-name> --namespace default
```

Within the next monitor cycle, a `SAFETYHOOK-MONITOR: FROZEN` log appears. After approximately 5 minutes (KubeVirt internal default), the VM auto-unfreezes and the next monitor cycle logs `SAFETYHOOK-MONITOR: RECOVERED`.

Verify in Observe > Logs (tenant Application):

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR"
```

### Alert 4: VirtFreezerActiveWithoutUnfreeze (manual verification)

Alert 4 depends on a mathematical difference between two log counts. To verify the imbalance manually, run in **Observe > Logs** (tenant **Application**):

```logql
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-pre" [30m]))
-
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-post" [30m]))
```

The alert fires when this value exceeds **5** for more than **5 minutes**.

To simulate:

```bash
oc run logger-test-freeze -n backup-netbackup \
  --image=busybox \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"logger-test-freeze","image":"busybox","args":["sh","-c","while true; do echo \"ProcessBackupExecHookRequest: Phase netbackup-pre\"; sleep 1; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sh -c 'placeholder'
```

Wait 5 to 6 minutes and check **Observe > Alerts** for `VirtFreezerActiveWithoutUnfreeze`.

### Clean up after testing

```bash
oc delete pod logger-test logger-test-timeout logger-test-freeze -n backup-netbackup --ignore-not-found
```

## Useful Queries

All queries run in **Observe > Logs**, tenant **Application**.

**Any storage error from the Hitachi VSP**

```logql
{ log_type="application" } |= "An error occurred in the storage system"
```

**LDEV ID exhaustion specifically (KART30000-E)**

```logql
{ log_type="application" } |= "no available LDEV ID in the system or resource groups"
```

**Backup controller timeout**

```logql
{ log_type="application" } |= "timed out waiting for the condition"
```

**Freeze/unfreeze balance**

```logql
{ log_type="application" } |= "Phase netbackup-pre"
```

```logql
{ log_type="application" } |= "Phase netbackup-post"
```

Imbalance as a single number (Metrics view):

```logql
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-pre" [30m]))
-
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-post" [30m]))
```

**All monitor events (frozen and recovered)**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR"
```

**Only frozen VMs**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR: FROZEN"
```

**Only recovered VMs (auto-unfreeze worked)**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR: RECOVERED"
```

**Monitor events for a specific VM**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR" |= "vm=win2k19"
```

**Monitor events for a specific namespace**

```logql
{ log_type="application" } |= "SAFETYHOOK-MONITOR" |= "namespace=my-database-ns"
```

## Context

These alerts were created in response to a production incident where the Hitachi VSP (`st05vsp3044`) exhausted available LDEV IDs, causing backup snapshot creation to fail with `KART30000-E / SSB1 [2E11]`. The NetBackup controller kept `virt-freezer --freeze` active on guest VMs while waiting for the snapshot timeout (~15 minutes). A Windows Server 2022 VM experienced a BSOD (stop code `0x0000001A / 0x3f`) because the VirtIO disk driver's `IoTimeoutValue` was not configured (defaulting to 60 seconds), causing a kernel panic when the frozen I/O exceeded the timeout.

Related remediation items outside this repo: configure `IoTimeoutValue = 300` for `viostor` and `vioscsi` VirtIO drivers on all migrated Windows VMs; configure LDEV pool threshold alerts on the Hitachi VSP Storage Navigator; review the NetBackup snapshot retention policy to prevent LDEV pool exhaustion.

> The 300-second value is a commonly recommended baseline for VMs with VirtIO drivers in environments where storage operations (snapshots, migrations, failovers) may temporarily delay I/O. Microsoft documents the default `TimeoutValue` registry key at learn.microsoft.com; the specific value for your environment should be validated with your storage vendor.
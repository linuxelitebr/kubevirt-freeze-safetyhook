# Hitachi VSP / NetBackup Alerts: OpenShift + Loki

Alerting stack for Hitachi VSP snapshot failures and NetBackup freeze-related incidents on OpenShift Virtualization clusters.

## Files

| File | Purpose |
|---|---|
| `01-alertingrule-hitachi-backup-alerts.yaml` | Defines 4 LogQL-based alerts via Loki Ruler |
| `02-alertmanagerconfig-backup-storage-routing.yaml` | Routes and delivers alert notifications |

> **Note:** The correct CRD for LogQL-based alerts is `AlertingRule` (`loki.grafana.com/v1`), not `PrometheusRule`. PrometheusRule only accepts PromQL and will reject LogQL expressions with a parse error on the `|` character.

## Alerts

| Alert | Severity | Fires when | `for` |
|---|---|---|---|
| `HitachiStorageError` | critical | Any VSP storage error in the last 5 min | immediate |
| `HitachiLDEVExhausted` | critical | LDEV ID exhaustion specifically (KART30000-E) | immediate |
| `NetBackupSnapshotTimeout` | critical | Backup controller timeout | 1 min |
| `VirtFreezerActiveWithoutUnfreeze` | warning | pre-hooks >> post-hooks for 5+ min | 5 min |

- Alerts 1 and 2 target the storage layer. Alert 1 is broader (any VSP error);  
- Alert 2 is specific to LDEV exhaustion and useful for Zabbix correlation.  
- Alert 3 fires when a **backup** job has already **failed** and VMs may be **frozen**.  
- Alert 4 is the early warning. It fires *before* the timeout, giving the team time to act before a forced shutdown causes a BSOD (stop code 0x1A).

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

### Label the application namespace

```bash
oc label namespace backup-netbackup openshift.io/cluster-monitoring=true
```

> These two steps are only needed if not already configured. Verify with:

> ```bash
> oc get lokistack logging-loki -n openshift-logging -o yaml | grep -A 10 "rules:"
> oc get namespace backup-netbackup --show-labels | grep cluster-monitoring
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

Loki-based alerts only appear in **Observe > Alerting > Alerts** when they are actively **firing**. In normal conditions (no errors) they are invisible in the
console, which is expected behavior.

To confirm the rules were loaded correctly, check the Ruler logs:

```bash
oc logs -n openshift-logging logging-loki-ruler-0 --since=5m \
  | grep -E "hitachi|backup|loaded|rules|updating"
```

A successful load shows:

```
msg="updating rule file" file=...backup-netbackup-hitachi-backup-alerts...
```

## Configure the notification receiver

Edit `02-alertmanagerconfig-backup-storage-routing.yaml` and fill in the notification channel your team uses:

- **Email**: fill in `to`, `from`, `smarthost`
- **Teams / generic webhook**: uncomment `webhookConfigs` and add the URL
- **Slack**: uncomment `slackConfigs`
- **PagerDuty**: uncomment `pagerdutyConfigs`

## Troubleshooting

```bash
# Check if the Ruler loaded the rules
oc logs -n openshift-logging logging-loki-ruler-0 --since=5m \
  | grep -E "hitachi|backup|loaded|rules|updating"

# Check AlertingRule was accepted
oc get alertingrule -n backup-netbackup

# Force Alertmanager reload if needed
oc delete pod -n openshift-monitoring -l app.kubernetes.io/name=alertmanager
```

**Common issues:**

| Symptom | Cause | Fix |
|---|---|---|
| `parse error: unexpected character '|'` | Wrong CRD. Using PrometheusRule instead of AlertingRule | Use `kind: AlertingRule` with `apiVersion: loki.grafana.com/v1` |
| `spec.tenantID: Invalid value: "application"` | AlertingRule in `openshift-logging` namespace | Move to `backup-netbackup` namespace |
| `spec.tenantID: Required value` | Missing `tenantID` field | Add `tenantID: "application"` under `spec` |
| Ruler logs show no trace of the rule | LokiStack `rules.selector` or namespace label missing | Apply LokiStack patch and label the namespace |
| Alerts not visible in Observe > Alerting > Alerting Rules | Expected. Loki rules only appear in Alerts tab when firing | Confirm via Ruler logs instead |

## Testing: Simulating a failure

Since alerts from the Loki Ruler only appear in the OpenShift console (**Observe > Alerts**) when actively firing, you can simulate a failure by injecting log messages manually.

The Loki collector (Vector) captures stdout from running containers. The test pods below generate log lines that match the alert filter expressions, causing the alerts to fire within 1–2 minutes.

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

### Verify the alert fired

```bash
# 1. Confirm logs are being generated
oc logs -n backup-netbackup logger-test

# 2. Confirm Loki indexed them. Run in Observe > Logs (tenant: Application)
# {log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "An error occurred in the storage system"

# 3. Wait 1-2 minutes, then check Observe > Alerts for status Firing
```

### Alert 4: VirtFreezerActiveWithoutUnfreeze (manual verification)

Alert 4 depends on a mathematical difference between two log counts, which makes it harder to validate visually. To verify the imbalance manually before the alert fires, run the following query in **Observe > Logs** (select tenant **Application**):

```logql
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-pre" [30m]))
-
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-post" [30m]))
```

The result is the number of pre-hooks with no corresponding post-hook in the last 30 minutes. The alert fires when this value exceeds **5** for more than **5 minutes**.

To simulate the imbalance, inject only pre-hook messages without matching post-hooks:

```bash
oc run logger-test-freeze -n backup-netbackup \
  --image=busybox \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"logger-test-freeze","image":"busybox","args":["sh","-c","while true; do echo \"ProcessBackupExecHookRequest: Phase netbackup-pre\"; sleep 1; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sh -c 'placeholder'
```

Wait 5–6 minutes (the `for: 5m` threshold) and check **Observe > Alerts** for the
`VirtFreezerActiveWithoutUnfreeze` warning.

### Clean up after testing

```bash
oc delete pod logger-test logger-test-timeout logger-test-freeze -n backup-netbackup --ignore-not-found
oc get pods -n backup-netbackup -w
```

## Useful Queries

All queries run in **Observe > Logs**, tenant **Application**.

**Any storage error from the Hitachi VSP**  
Broad catch-all. Useful for initial triage. Covers LDEV exhaustion, full DP pool, Thin Image limits, and any other array-side failure.

```logql
{log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "An error occurred in the storage system"
```

**LDEV ID exhaustion specifically (KART30000-E)**  
Narrows down to the exact error that caused this incident. If you see this, the Hitachi VSP resource group has no available LDEV IDs. No new snapshots
can be created until the pool is freed up.

```logql
{log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "no available LDEV ID in the system or resource groups"
```

**Backup controller timeout**  
Fires after the controller gives up waiting 15 minutes for a snapshot. At this point the backup has already failed, but more importantly, VMs may
still have an active filesystem freeze. Do not reboot or shut down any VM without checking the freeze state first.

```logql
{log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "timed out waiting for the condition"
```

**Freeze/unfreeze balance**  
Run both queries over the same time window and compare the counts.  
Pre-hooks trigger `virt-freezer --freeze`; post-hooks trigger the corresponding `--unfreeze`. If pre significantly outnumbers post, one or more VMs are frozen
and waiting for a backup operation that may have already failed.

```logql
{log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-pre"
```

```logql
{log_type="application", kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-post"
```

To calculate the imbalance as a single number, switch to the **Metrics** view and run:

```logql
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-pre" [30m]))
-
sum(count_over_time({kubernetes_namespace_name="backup-netbackup"} |= "Phase netbackup-post" [30m]))
```

A result above 5 sustained for more than 5 minutes triggers the `VirtFreezerActiveWithoutUnfreeze` alert.

## Context

These alerts were created in response to a production incident where the Hitachi VSP (`st05vsp3044`) exhausted available LDEV IDs, causing backup snapshot creation to fail with `KART30000-E / SSB1 [2E11]`. The NetBackup controller kept `virt-freezer --freeze` active on guest VMs while waiting for the snapshot timeout (~15 minutes). A Windows Server 2022 VM experienced a BSOD (stop code `0x0000001A / 0x3f`) because the VirtIO disk driver's `IoTimeoutValue` was not configured (defaulting to 60 seconds), causing a kernel panic when the frozen I/O exceeded the timeout.

Related remediation items outside this repo: configure `IoTimeoutValue = 300` for `viostor` and `vioscsi` VirtIO drivers on all migrated Windows VMs; configure LDEV pool threshold alerts on the Hitachi VSP Storage Navigator; review the NetBackup snapshot retention policy to prevent LDEV pool exhaustion.

> The 300-second value is a commonly recommended baseline for VMs with VirtIO drivers in environments where storage operations (snapshots, migrations, failovers) may temporarily delay I/O. Microsoft documents the default `TimeoutValue` registry key at learn.microsoft.com; the specific value for your environment should be validated with your storage vendor.
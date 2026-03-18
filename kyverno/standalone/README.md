# Kyverno on Standalone OpenShift

## Install Kyverno

**Note on Kyverno version:** This solution has been validated with Helm chart version 3.2.7. Later versions may work but have not been fully tested. If you 
experience issues with webhook registration or policies not being applied, downgrade to 3.2.7 by adding `--version 3.2.7` to the `helm install` command.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2

kubectl wait --for=condition=Ready pods \
  -l app.kubernetes.io/instance=kyverno \
  -n kyverno --timeout=300s
```

## Apply SCC (OpenShift-specific)

The background controller needs permission to update virt-launcher pods, which run under a KubeVirt-specific SCC:

```bash
oc adm policy add-scc-to-user privileged \
  system:serviceaccount:kyverno:kyverno-background-controller
```

## Label Your Namespaces

The policies use a `namespaceSelector` to target namespaces with the label `backup-safetyhook=enabled`. Label every namespace that has VMs you want to protect:

```bash
oc label namespace my-database-ns backup-safetyhook=enabled
oc label namespace my-workload-ns backup-safetyhook=enabled
oc label namespace another-ns backup-safetyhook=enabled
```

To add more namespaces later, just label them. No need to edit the policies.

To remove a namespace from protection:

```bash
oc label namespace my-workload-ns backup-safetyhook-
```

## Apply RBAC and Policies

```bash
oc apply -f 01-rbac.yaml
oc apply -f 02-policy-safetyhook.yaml
oc apply -f 03-policy-reconcile.yaml
```

**Note on the reconcile policy (03):** The `targets[]` section does not support `namespaceSelector`. You need to list each namespace explicitly there. Edit `03-policy-reconcile.yaml` and add one target entry per namespace:

```yaml
targets:
- apiVersion: v1
  kind: Pod
  namespace: my-database-ns
- apiVersion: v1
  kind: Pod
  namespace: my-workload-ns
- apiVersion: v1
  kind: Pod
  namespace: another-ns
```

The admission policy (02) uses `namespaceSelector` and does not need editing when adding namespaces.

## Verify

```bash
oc get clusterpolicies

# Expected:
# safetyhook-db-admission    true   false   True
# safetyhook-db-reconcile    true   true    True
```

Check that pods got the safety-net annotations:

```bash
oc get pods -n <namespace> -l kubevirt.io=virt-launcher \
  -o json | jq '.items[] | {
    name: .metadata.name,
    timeout: .metadata.annotations["pre.hook.backup.velero.io/timeout"],
    on_error: .metadata.annotations["pre.hook.backup.velero.io/on-error"]
  }'

# Expected: timeout "180s", on_error "Continue"
```

If existing pods don't get updated after a few minutes, restart the VMs. The admission policy will apply the full safety-net on the new pods.

## Uninstall

```bash
oc delete -f 03-policy-reconcile.yaml
oc delete -f 02-policy-safetyhook.yaml
oc delete -f 01-rbac.yaml
helm uninstall kyverno -n kyverno
```

Hook annotations will revert to originals on next VM restart.

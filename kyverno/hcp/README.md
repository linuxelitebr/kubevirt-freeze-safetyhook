# Kyverno on HyperShift (Hosted Control Planes)

On HyperShift, the API server runs in the management cluster and communicates with webhooks via Konnectivity. Kyverno can't auto-generate its TLS certificates during bootstrap, so you need to provide them manually.

## Install Kyverno

**Important:** On HyperShift, use Kyverno Helm chart version **3.2.7**. Later versions (3.7.x+) attempt to use the `MutatingAdmissionPolicy v1alpha1` 
API, which may not be available on HyperShift hosted clusters, preventing the admission webhook from registering.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --version 3.2.7 \
  --create-namespace \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2
```

* The rest of the configuration is the same as in the standalone version.

## Step 1: Generate TLS Certificates

```bash
# Generate a self-signed CA
openssl genrsa -out rootCA.key 4096
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 36500 \
  -out rootCA.crt -subj "/CN=kyverno-ca"

# Generate key and CSR for the admission controller
openssl genrsa -out tls.key 4096
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=kyverno-svc.kyverno.svc" \
  -addext "subjectAltName=DNS:kyverno-svc,DNS:kyverno-svc.kyverno,DNS:kyverno-svc.kyverno.svc,DNS:kyverno-svc.kyverno.svc.cluster.local"

# Sign with the CA
openssl x509 -req -in tls.csr -CA rootCA.crt -CAkey rootCA.key \
  -CAcreateserial -out tls.crt -days 36500 -sha256 \
  -extfile <(echo "subjectAltName=DNS:kyverno-svc,DNS:kyverno-svc.kyverno,DNS:kyverno-svc.kyverno.svc,DNS:kyverno-svc.kyverno.svc.cluster.local")
```

## Step 2: Create Secrets BEFORE Installing Kyverno

The secrets must exist before `helm install`. Kyverno detects existing secrets and uses them instead of trying to generate new ones.

```bash
oc create namespace kyverno

oc create secret tls \
  kyverno-svc.kyverno.svc.kyverno-tls-pair \
  --cert=tls.crt --key=tls.key -n kyverno

oc create secret generic \
  kyverno-svc.kyverno.svc.kyverno-tls-ca \
  --from-file=rootCA.crt -n kyverno
```

## Step 3: Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --set admissionController.replicas=3 \
  --set admissionController.rbac.create=true \
  --set admissionController.container.image.pullPolicy=IfNotPresent \
  --set admissionController.certManager.enabled=false \
  --set admissionController.service.port=9443 \
  --set features.admissionWebhookCEL.enabled=false \
  --set features.mutatingAdmissionPolicyReports.enabled=false \
  --set features.validatingAdmissionPolicyReports.enabled=false
```

Wait for pods to be ready:

```bash
kubectl wait --for=condition=Ready pods \
  -l app.kubernetes.io/instance=kyverno \
  -n kyverno --timeout=300s
```

```bash
oc -n kyverno get all
```

If the admission controller is not becoming Ready, restart it:

```bash
oc rollout restart deployment kyverno-admission-controller -n kyverno
```

## Step 4: Verify TLS

```bash
# All 4 secrets should exist
oc get secret -n kyverno | grep tls

# Expected:
# kyverno-cleanup-controller.kyverno.svc.kyverno-tls-ca     kubernetes.io/tls
# kyverno-cleanup-controller.kyverno.svc.kyverno-tls-pair   kubernetes.io/tls
# kyverno-svc.kyverno.svc.kyverno-tls-ca                    kubernetes.io/tls
# kyverno-svc.kyverno.svc.kyverno-tls-pair                  kubernetes.io/tls

# All pods Running and Ready
oc get pods -n kyverno
```

## Step 5: Apply SCC, Label Namespaces, and Deploy Policies

```bash
oc adm policy add-scc-to-user privileged \
  system:serviceaccount:kyverno:kyverno-background-controller
```

Label namespaces you want to protect:

```bash
oc label namespace my-database-ns backup-safetyhook=enabled
oc label namespace my-workload-ns backup-safetyhook=enabled
```

The policy files are the same as standalone:

```bash
oc apply -f ../standalone/01-rbac.yaml
oc apply -f ../standalone/02-policy-safetyhook.yaml
oc apply -f ../standalone/03-policy-reconcile.yaml
```

**Remember** to edit `03-policy-reconcile.yaml` and add your namespaces to the `targets[]` section (see standalone README for details).

## Troubleshooting

### Collecting Logs
oc logs -n kyverno -l app.kubernetes.io/component=background-controller --tail=20
oc logs -n kyverno -l app.kubernetes.io/component=background-controller -f | grep -i "safetyhook\|$NS\|mutate"

### TLS handshake errors in logs

```
secret "kyverno-svc.kyverno.svc.kyverno-tls-pair" not found
```

The TLS secrets were not created before Kyverno was installed. Delete and recreate following steps 2-3 above.

### MutatingAdmissionPolicy errors

```
failed to list *v1alpha1.MutatingAdmissionPolicy: the server could not find the requested resource
```

These are warnings, not errors. The `v1alpha1.MutatingAdmissionPolicy` API is a Kubernetes feature gate not enabled on HyperShift. Kyverno logs these but continues working normally. Safe to ignore.

### Admission controller in CrashLoop

Check if the init container completed:

```bash
oc describe pod -n kyverno -l app.kubernetes.io/component=admission-controller
```

If `kyverno-pre` init container fails, the RBAC may be insufficient:

```bash
oc adm policy add-scc-to-user anyuid -z kyverno-admission-controller -n kyverno
oc rollout restart deployment kyverno-admission-controller -n kyverno
```

## Uninstall

```bash
helm uninstall kyverno -n kyverno
oc get crd -o name | grep kyverno | xargs oc delete
oc delete namespace kyverno

# Remove orphaned webhooks:
oc get mutatingwebhookconfiguration -o name | grep kyverno | xargs oc delete
oc get validatingwebhookconfiguration -o name | grep kyverno | xargs oc delete
```

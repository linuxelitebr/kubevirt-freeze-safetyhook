# Kyverno Deployment

Kyverno acts as an admission webhook that intercepts virt-launcher pod creation and replaces the Velero hook annotations with safety-net versions in real-time. No delay, no window of exposure.

## Choose Your Flavor

### Standalone OpenShift Cluster

Kyverno generates its own TLS certificates automatically.

```bash
cd standalone/
```

See [standalone/README.md](standalone/README.md) for instructions.

### HyperShift (Hosted Control Planes)

Kyverno can't auto-generate TLS certificates on HyperShift because the API server runs in the management cluster and can't reach the webhook during bootstrap. You need to provide certificates manually before installation.

```bash
cd hcp/
```

See [hcp/README.md](hcp/README.md) for instructions.

## What Is Kyverno?

Kyverno is a CNCF-graduated policy engine for Kubernetes. It intercepts API server requests (create, update, delete) and applies rules written in plain
YAML. No programming language needed.

We use its mutation capability: Kyverno intercepts virt-launcher pod creation and replaces the backup hook annotations with safety-net versions before the
pod exists.

More info: https://kyverno.io

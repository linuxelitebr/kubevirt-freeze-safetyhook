#!/bin/bash
# ============================================================================
# Incident data collection -- VM BSOD + Backup + CSI
# Run this as soon as possible after the incident
# ============================================================================

NAMESPACE="your-vm-namespace"
BACKUP_NS="your-backup-namespace"
STORAGE_NS="your-storage-namespace"
CNV_NS="openshift-cnv"
OUTPUT_DIR="/tmp/incident-collection-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${OUTPUT_DIR}"
echo "Coletando dados em: ${OUTPUT_DIR}"
echo "Inicio: $(date -u)" | tee "${OUTPUT_DIR}/00-collection-metadata.txt"

# ----------------------------------------------------------------------------
# 1. ESTADO ATUAL DAS VMs
# ----------------------------------------------------------------------------
echo "[1/10] Estado das VMs..."

oc get vm -n ${NAMESPACE} -o wide > "${OUTPUT_DIR}/01-vms.txt" 2>&1
oc get vmi -n ${NAMESPACE} -o wide > "${OUTPUT_DIR}/01-vmis.txt" 2>&1
oc get vmi -n ${NAMESPACE} -o yaml > "${OUTPUT_DIR}/01-vmis-full.yaml" 2>&1

# Status do freeze em cada VMI
for VMI in $(oc get vmi -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "=== ${VMI} ===" >> "${OUTPUT_DIR}/01-vmi-freeze-status.txt"
  oc describe vmi ${VMI} -n ${NAMESPACE} 2>&1 | grep -iE 'freeze|agent|phase|status|condition' \
    >> "${OUTPUT_DIR}/01-vmi-freeze-status.txt"
  echo "" >> "${OUTPUT_DIR}/01-vmi-freeze-status.txt"
done

# ----------------------------------------------------------------------------
# 2. EVENTOS (CRITICO -- coletar antes que expirem)
# ----------------------------------------------------------------------------
echo "[2/10] Eventos..."

oc get events -n ${NAMESPACE} --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/02-events-vms.txt" 2>&1
oc get events -n ${BACKUP_NS} --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/02-events-backup.txt" 2>&1
oc get events -n ${STORAGE_NS} --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/02-events-storage.txt" 2>&1
oc get events -n ${CNV_NS} --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/02-events-cnv.txt" 2>&1
oc get events -A --sort-by='.lastTimestamp' --field-selector reason=FailedAttachVolume > "${OUTPUT_DIR}/02-events-volume-failures.txt" 2>&1

# ----------------------------------------------------------------------------
# 3. LOGS CSI DRIVER (controller + node plugins)
# ----------------------------------------------------------------------------
echo "[3/10] Logs CSI driver..."

for POD in $(oc get pod -n ${STORAGE_NS} -l app=hspc-csi-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  for CONTAINER in hspc-csi-driver csi-provisioner csi-snapshotter csi-attacher csi-resizer; do
    oc logs ${POD} -n ${STORAGE_NS} -c ${CONTAINER} --since=6h \
      > "${OUTPUT_DIR}/03-csi-${POD}-${CONTAINER}.log" 2>&1
  done
done

for POD in $(oc get pod -n ${STORAGE_NS} -l app=hspc-csi-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc logs ${POD} -n ${STORAGE_NS} -c hspc-csi-driver --since=6h \
    > "${OUTPUT_DIR}/03-csi-node-${POD}.log" 2>&1
done

# ----------------------------------------------------------------------------
# 4. LOGS BACKUP OPERATOR
# ----------------------------------------------------------------------------
echo "[4/10] Logs backup operator..."

for POD in $(oc get pod -n ${BACKUP_NS} -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc logs ${POD} -n ${BACKUP_NS} --all-containers --since=6h \
    > "${OUTPUT_DIR}/04-backup-${POD}.log" 2>&1
done

# CRs do backup operator (backups, snapshots, configs)
for CRD in $(oc get crd -o name 2>/dev/null | grep -i backup | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  RESOURCE=$(echo ${CRD} | cut -d. -f1)
  oc get ${RESOURCE} -n ${BACKUP_NS} -o yaml \
    > "${OUTPUT_DIR}/04-backup-cr-${RESOURCE}.yaml" 2>&1
done

# ----------------------------------------------------------------------------
# 5. LOGS VIRT-LAUNCHER (VMs afetadas)
# ----------------------------------------------------------------------------
echo "[5/10] Logs virt-launcher..."

for POD in $(oc get pod -n ${NAMESPACE} -l kubevirt.io=virt-launcher -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  # Logs atuais
  oc logs ${POD} -n ${NAMESPACE} -c compute --since=6h \
    > "${OUTPUT_DIR}/05-virt-launcher-${POD}-compute.log" 2>&1
  oc logs ${POD} -n ${NAMESPACE} -c guest-console-log --since=6h \
    > "${OUTPUT_DIR}/05-virt-launcher-${POD}-console.log" 2>&1

  # Logs do pod anterior (se a VM reiniciou)
  oc logs ${POD} -n ${NAMESPACE} -c compute --previous \
    > "${OUTPUT_DIR}/05-virt-launcher-${POD}-compute-previous.log" 2>&1

  # Annotations de hook (evidencia do freeze config)
  echo "=== ${POD} ===" >> "${OUTPUT_DIR}/05-hook-annotations.txt"
  oc get pod ${POD} -n ${NAMESPACE} -o jsonpath='{.metadata.annotations}' 2>&1 | \
    python3 -m json.tool >> "${OUTPUT_DIR}/05-hook-annotations.txt" 2>&1
  echo "" >> "${OUTPUT_DIR}/05-hook-annotations.txt"
done

# ----------------------------------------------------------------------------
# 6. LOGS VIRT-HANDLER E VIRT-CONTROLLER
# ----------------------------------------------------------------------------
echo "[6/10] Logs KubeVirt controllers..."

for POD in $(oc get pod -n ${CNV_NS} -l kubevirt.io=virt-handler -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc logs ${POD} -n ${CNV_NS} --since=6h \
    > "${OUTPUT_DIR}/06-virt-handler-${POD}.log" 2>&1
done

for POD in $(oc get pod -n ${CNV_NS} -l kubevirt.io=virt-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc logs ${POD} -n ${CNV_NS} --since=6h \
    > "${OUTPUT_DIR}/06-virt-controller-${POD}.log" 2>&1
done

# ----------------------------------------------------------------------------
# 7. PVCs, PVs e VOLUMESNAPSHOTS
# ----------------------------------------------------------------------------
echo "[7/10] Volumes e snapshots..."

oc get pvc -n ${NAMESPACE} -o wide > "${OUTPUT_DIR}/07-pvcs-vms.txt" 2>&1
oc get pvc -n ${BACKUP_NS} -o wide > "${OUTPUT_DIR}/07-pvcs-backup.txt" 2>&1
oc get pv -o wide | grep -E "${NAMESPACE}|${BACKUP_NS}" > "${OUTPUT_DIR}/07-pvs.txt" 2>&1

oc get volumesnapshot -n ${NAMESPACE} -o yaml > "${OUTPUT_DIR}/07-volumesnapshots-vms.yaml" 2>&1
oc get volumesnapshot -n ${BACKUP_NS} -o yaml > "${OUTPUT_DIR}/07-volumesnapshots-backup.yaml" 2>&1
oc get volumesnapshotcontent -o yaml > "${OUTPUT_DIR}/07-volumesnapshotcontent.yaml" 2>&1

# ----------------------------------------------------------------------------
# 8. ESTADO DOS NODES (CPU, memoria, pods)
# ----------------------------------------------------------------------------
echo "[8/10] Estado dos nodes..."

oc adm top node > "${OUTPUT_DIR}/08-node-resources.txt" 2>&1
oc get nodes -o wide > "${OUTPUT_DIR}/08-nodes.txt" 2>&1

# Pods por node (para ver densidade)
for NODE in $(oc get pod -n ${NAMESPACE} -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u); do
  echo "=== ${NODE} ===" >> "${OUTPUT_DIR}/08-pods-per-node.txt"
  oc get pod --all-namespaces --field-selector spec.nodeName=${NODE} --no-headers 2>/dev/null | wc -l \
    >> "${OUTPUT_DIR}/08-pods-per-node.txt"
  oc adm top pod --all-namespaces --field-selector spec.nodeName=${NODE} 2>/dev/null | head -20 \
    >> "${OUTPUT_DIR}/08-pods-per-node.txt"
  echo "" >> "${OUTPUT_DIR}/08-pods-per-node.txt"
done

# ----------------------------------------------------------------------------
# 9. CONFIG DO KUBEVIRT / HYPERCONVERGED
# ----------------------------------------------------------------------------
echo "[9/10] Config KubeVirt..."

oc get hyperconverged -n ${CNV_NS} -o yaml > "${OUTPUT_DIR}/09-hyperconverged.yaml" 2>&1
oc get kubevirt -n ${CNV_NS} -o yaml > "${OUTPUT_DIR}/09-kubevirt.yaml" 2>&1

# VM templates (para verificar se ioThreads/blockMultiQueue esta configurado)
for VM in $(oc get vm -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | head -3); do
  oc get vm ${VM} -n ${NAMESPACE} -o yaml > "${OUTPUT_DIR}/09-vm-sample-${VM}.yaml" 2>&1
done

# ----------------------------------------------------------------------------
# 10. STORAGECLASS E SNAPSHOTCLASS
# ----------------------------------------------------------------------------
echo "[10/10] Storage classes..."

oc get storageclass -o yaml | grep -A20 "csi" > "${OUTPUT_DIR}/10-storageclass-csi.yaml" 2>&1
oc get volumesnapshotclass -o yaml > "${OUTPUT_DIR}/10-volumesnapshotclass.yaml" 2>&1

# ----------------------------------------------------------------------------
# EMPACOTAMENTO
# ----------------------------------------------------------------------------
echo ""
echo "Fim: $(date -u)" | tee -a "${OUTPUT_DIR}/00-collection-metadata.txt"
echo "Compactando..."

tar czf "${OUTPUT_DIR}.tar.gz" -C /tmp "$(basename ${OUTPUT_DIR})"
echo ""
echo "============================================"
echo "Coleta finalizada: ${OUTPUT_DIR}.tar.gz"
echo "Tamanho: $(du -h ${OUTPUT_DIR}.tar.gz | cut -f1)"
echo "============================================"
echo ""
echo "Envie o arquivo ${OUTPUT_DIR}.tar.gz para analise."

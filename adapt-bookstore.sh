#!/usr/bin/env bash
# Adapt pratjainvmw/bookstore-app for the mantis (dev branch) and drax (main branch) VKS clusters.
# Run from the repo root, on the dev branch:   git checkout dev && bash adapt-bookstore.sh
set -euo pipefail

OLD_HARBOR='harbor.lab.worker-node.com'
HARBOR='harbor.lab.worker-node.com'
OLD_SC='hawkeye-storage-policy'
SC='hawkeye-storage-policy'
DOMAIN='lab.worker-node.com'
GH_REPO='https://github.com/pratjainvmw/bookstore-app'
ARGOCD_NS="carbon"

# ---------- a) Harbor FQDN, everywhere (manifests, scripts, CI, docs) ----------
grep -rlI --exclude-dir=.git -F "$OLD_HARBOR" . | xargs sed -i "s/harbor-01a\.vcf\.lab/${HARBOR}/g"

# ---------- b) Storage policy / StorageClass ----------
grep -rlI --exclude-dir=.git -F "$OLD_SC" . | xargs sed -i "s/${OLD_SC}/${SC}/g"

# ---------- c) One overlay per cluster, cloned from lab ----------
for C in mantis drax; do
  O="kubernetes/overlays/${C}"
  rm -rf "$O" && cp -r kubernetes/overlays/lab "$O"

  # hostname for HTTPRoute + certificate
  sed -i "s/bookstore-test\.vcf\.lab/bookstore-${C}.${DOMAIN}/" "$O/httproute-patch.yaml" "$O/tls-patch.yaml"
  # reader/chatbot are not deployed; links just point at would-be hostnames
  sed -i "s#http://reader-test\.vcf\.lab#https://reader-${C}.${DOMAIN}#; s#http://chatbot-test\.vcf\.lab#https://chatbot-${C}.${DOMAIN}#" "$O/configmap-patch.yaml"

  # kustomization: no Harbor password in git, and an app image entry the CI sed can bump
  cat > "$O/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: bookstore

resources:
  - ../../base

components:
  - ../../components/init-db

# CI bumps the newTag line directly below the app image name (keep them adjacent)
images:
  - name: ${HARBOR}/bookstore/app
    newTag: latest

# harbor-registry-secret is created by hand on the cluster (not stored in git)
secretGenerator:
  - name: app-secrets
    literals:
      - DB_USER=bookstore
      - DB_PASSWORD=bookstore-secret-pw
      - MINIO_ACCESS_KEY=minioadmin
      - MINIO_SECRET_KEY=minioadmin-secret

patches:
  - path: configmap-patch.yaml
  - path: namespace-patch.yaml
  - path: httproute-patch.yaml
  - path: tls-patch.yaml
  - path: postgres-patch.yaml
  - path: redis-pvc-patch.yaml
  - path: minio-pvc-patch.yaml
  - path: init-db-job-patch.yaml
  # Elasticsearch disabled (same as upstream lab). To enable: remove the two
  # delete patches below, uncomment elasticsearch-patch.yaml, and set ES_URL in configmap-patch.yaml.
  - patch: |-
      \$patch: delete
      apiVersion: apps/v1
      kind: StatefulSet
      metadata:
        name: elasticsearch
  - patch: |-
      \$patch: delete
      apiVersion: v1
      kind: Service
      metadata:
        name: elasticsearch-service
  # - path: elasticsearch-patch.yaml
EOF
done

# ---------- d) CI: build on dev+main, bump the overlay that matches the branch ----------
for WF in .github/workflows/ci.yml .github/workflows/deploy.yml; do
  sed -i \
    -e 's/branches: \[ main, develop \]/branches: [ main, dev ]/' \
    -e "s/if: github.ref == 'refs\/heads\/main' \&\& github.event_name == 'push'/if: github.event_name == 'push'/" \
    -e 's#cd kubernetes/base#cd kubernetes/overlays/${OVERLAY}#' \
    -e 's#kubernetes/base/kustomization.yaml#kubernetes/overlays/${OVERLAY}/kustomization.yaml#g' \
    -e 's#git push origin HEAD:main#git push origin HEAD:${GITHUB_REF_NAME}#' \
    "$WF"
done
# OVERLAY env: main -> drax, anything else (dev) -> mantis
sed -i "/GOMODCACHE: \/mnt\/data\/go-mod-cache/a\\      OVERLAY: \${{ github.ref_name == 'main' \&\& 'drax' || 'mantis' }}" .github/workflows/ci.yml
sed -i "/runs-on: \[self-hosted, linux, harbor\]/a\\    env:\\n      OVERLAY: \${{ github.ref_name == 'main' \&\& 'drax' || 'mantis' }}" .github/workflows/deploy.yml

# ---------- e) Argo CD: replace upstream apps with one Application per cluster ----------
git rm -q argocd-apps/apps.yaml argocd-apps/bookstore.yaml argocd-apps/reader.yaml argocd-apps/chatbot.yaml
for pair in mantis:dev drax:main; do
  C="${pair%%:*}"; BR="${pair##*:}"
  cat > "argocd-apps/bookstore-${C}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bookstore-${C}
  namespace: ${ARGOCD_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GH_REPO}
    targetRevision: ${BR}
    path: kubernetes/overlays/${C}
  destination:
    name: ${C}            # must match: argocd cluster add <ctx> --name ${C}
    namespace: bookstore
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
EOF
done

echo "Done. Review with: git status && git diff --stat"

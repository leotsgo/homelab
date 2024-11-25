#!/bin/bash

# Create main directories (skipping clusters/production as it already exists)
mkdir -p {apps,infrastructure}/{base,production,staging}
mkdir -p clusters/staging

# Create basic kustomization files for apps
cat >apps/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []  # Add your base applications here
EOF

cat >apps/production/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches: []  # Add your production-specific patches here
EOF

cat >apps/staging/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches: []  # Add your staging-specific patches here
EOF

# Create basic kustomization files for infrastructure
cat >infrastructure/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []  # Add your base infrastructure components here
EOF

cat >infrastructure/production/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches: []  # Add your production-specific infrastructure patches here
EOF

cat >infrastructure/staging/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches: []  # Add your staging-specific infrastructure patches here
EOF

# Create Flux Kustomization for production cluster
cat >clusters/production/infrastructure.yaml <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/production
  prune: true
EOF

cat >clusters/production/apps.yaml <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m0s
  dependsOn:
    - name: infrastructure
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/production
  prune: true
EOF

# Update .gitignore if it doesn't exist
if [ ! -f .gitignore ]; then
	cat >.gitignore <<'EOF'
# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
EOF
fi

# Add and commit new files
git add .
git commit -m "feat: Add Flux repository structure"

echo "Flux repository structure has been updated successfully!"

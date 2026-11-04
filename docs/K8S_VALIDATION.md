# Kubernetes / EKS guide verification

Date: 2026-11-04.

Performed locally:

- Downloaded official Helm v4.0.0 Windows binary to a temporary directory and verified the archive SHA-256 against the published checksum.
- `helm lint --strict` passed for the URL Shortener chart.
- Rendered kind, EKS HTTP and EKS TLS values; parsed the resulting YAML and checked namespace, image references, Secret references, PVC classes, data Services, GHCR pull settings and frontend listener/scheme.
- Checked all generated guide code appendices against source files.
- Checked Bash syntax for guide blocks and repository shell scripts.
- Existing Compose configuration checks still pass.
- Verified AWS Load Balancer Controller v2.14.1 chart metadata is chart 1.14.1 in its official source.

Not performed:

- No kind cluster, Kubernetes server-side admission or container integration test.
- No eksctl provisioning, AWS account entitlement test, IAM/Pod Identity association or EBS/NLB creation.
- No actual smoke, persistence, backup/restore, TLS, rollback or cloud teardown exercise.

Run the guide on VMware and record real evidence before claiming those outcomes. `validate_k8s_eks_guide.py` at workspace root checks Helm rendering without accessing a cluster; it is not an EKS integration test.

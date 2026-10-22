# Event-Network-Hub-Gitops

The desired state of everything that runs **inside** the Event Network Hub Kubernetes clusters.
Argo CD watches this repository and keeps the clusters matching it.

| Layer | Managed by |
|---|---|
| AWS foundations: accounts, VPCs, EKS, ECR, IAM roles for controllers, RDS, S3 | [Terraform-platform](https://github.com/BernardoJose90/Terraform-platform) |
| Cluster add-ons, platform APIs and application workloads | **This repository**, synced by Argo CD |
| Application code, CI, image builds, `catalog-info.yaml` | [event-network-hub](https://github.com/BernardoJose90/event-network-hub) |

## Layout

```
.github/workflows/              Checks on this repo (manifest validation, image tag bumps)
bootstrap/                      One-time install of Argo CD + the root Application
argocd/
├── projects/                   AppProjects: what platform and apps may deploy, and where
└── applicationsets/            Generates one Application per apps/<app>/envs/<env>
platform/                       Cluster add-ons, one folder each (Helm values + extra manifests)
├── argocd/                     Argo CD's own config (it manages itself after bootstrap)
├── crossplane/                 Crossplane core
├── crossplane-providers/       AWS providers and composition functions
├── crossplane-compositions/    The platform's APIs (XRDs + Compositions)
├── external-secrets/           AWS Secrets Manager → Kubernetes Secrets
├── aws-load-balancer-controller/  Ingress → ALB
├── karpenter/                  Node autoscaling (AWS side is in Terraform-platform)
├── cert-manager/               TLS certificates (optional if ACM is used)
├── external-dns/               Route53 records from Ingress hosts (optional)
├── monitoring/                 Metrics, logs, alerts
├── policy/                     Admission policies (Kyverno or Gatekeeper)
└── backstage/                  Backstage deployment (its source code lives in its own repo)
backstage/templates/            Backstage software templates ("create a new service")
apps/
└── event-network-hub/
    ├── base/                   Same in every environment: api, worker, web, gotenberg, migrations
    │   └── claims/             Crossplane requests for this app's own cloud resources
    └── envs/                   Per-environment overlays: image tags, replicas, config, secrets
        ├── development/        The folder name is the namespace
        ├── staging/
        └── production/
```

An environment's folder name is used as its namespace. It must match the namespace of the app's Pod Identity
association in Terraform-platform (`development` today).

Resources Terraform-platform already owns (for example the app's RDS database and S3 bucket) are never
also requested through Crossplane: one tool owns each resource.

## Build order

Each step is its own pull request and is checked on the cluster before the next one starts.

1. `bootstrap/`, `argocd/projects/`, `platform/argocd/`
2. `.github/workflows/` (validation)
3. `platform/aws-load-balancer-controller/`, `platform/karpenter/`
4. `platform/external-secrets/`
5. `apps/event-network-hub/` (development) + `argocd/applicationsets/`
6. Image tag bump workflow
7. `platform/crossplane/` → `crossplane-providers/` → `crossplane-compositions/`
8. `platform/backstage/`, then `backstage/templates/`
9. `monitoring/`, `policy/`, then staging and production

## Production readiness checklist

Based on the Argo CD, Crossplane, Backstage and AWS EKS documentation.

**Repository governance**
- [ ] Branch protection on `main`: pull requests, required checks, no force pushes
- [ ] `CODEOWNERS`: `argocd/` and `platform/` owned by platform admins ([ApplicationSet security](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Security/))
- [ ] The `project` field is hard-coded (never templated) in every ApplicationSet
- [ ] No secrets in git. Use External Secrets only ([secret management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/))

**Argo CD**
- [ ] SSO (IAM Identity Center) instead of the local admin user, plus RBAC by group ([security](https://argo-cd.readthedocs.io/en/stable/operator-manual/security/))
- [ ] Narrow Argo CD's cluster-admin ClusterRoles; TLS for Redis
- [ ] HA install in production (needs at least 3 nodes, 3+ `argocd-server` replicas) ([HA](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/))
- [ ] Crossplane settings: annotation tracking, Crossplane health checks, `ProviderConfigUsage` exclusion, `ARGOCD_K8S_CLIENT_QPS=300` ([Crossplane with Argo CD](https://docs.crossplane.io/latest/guides/crossplane-with-argo-cd/))

**Environments**
- [ ] Production on its own cluster (its own AWS account). Use an ApplicationSet cluster generator with labelled cluster secrets ([cluster bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/))
- [ ] Promotion by pull request: copy the image tag from one `envs/` folder to the next
- [ ] Image tags are commit SHAs, never `latest`; chart versions pinned

**Platform**
- [ ] Crossplane compositions versioned as Configuration packages ([configurations](https://docs.crossplane.io/latest/packages/configurations/))
- [ ] Monitoring and alerting for the add-ons and the apps
- [ ] Admission policies: non-root, resource limits, allowed registries (ECR only)
- [ ] `catalog-info.yaml` kept in each app's own repo ([Backstage catalog](https://backstage.io/docs/features/software-catalog/))

**Prerequisites in Terraform-platform**
- [ ] `eks_enabled = true` for the development cluster
- [ ] Pod Identity roles for External Secrets and the Crossplane AWS provider
- [ ] `karpenter.sh/discovery` tag on the node security group
- [ ] RDS and S3 for the app, and permissions on the app's role

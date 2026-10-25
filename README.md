# infra

What the Shortly services share for deployment: the Helm chart `charts/shortly-service` and the
pipelines that build, check and deploy them. Each service keeps only its values,
`charts/values.production.yaml`, a smoke test, and two short workflows that call the shared ones.
The deploy installs the published chart with the service's values:

```bash
helm upgrade --install dashboard-service oci://$ECR_REGISTRY/charts/shortly-service --version 1.0.0 \
  --namespace shortly --values charts/values.production.yaml \
  --set image.repository=$ECR_REGISTRY/shortly/dashboard-service --set image.digest=sha256:… \
  --set datadog.version=v1.4.0
```

The release name is the service's name, and every resource is named after it.

## The chart

Per service: a Deployment, a Service, a CPU-based HorizontalPodAutoscaler, a NetworkPolicy, one
ExternalSecret per `externalSecrets.secrets` entry (all loaded into the pods with `envFrom`), an
Ingress when `ingress.host` is set, and a PodDisruptionBudget when `minAvailable` is set.
`values.yaml` lists every setting with its default.

- Pods run as non-root (uid 10001) with the runtime's seccomp profile, no privilege escalation,
  no Linux capabilities and a read-only root filesystem (`/tmp` is an `emptyDir`), and without a
  Kubernetes API token (the services never call it).
- Probes use Spring Boot's actuator on the management port. The startup probe allows 5 minutes,
  which covers a dashboard migrating its schema on startup.
- Datadog: unified service tagging labels (`service` = the release name, `version` = the release
  tag) and an OpenMetrics check on `/actuator/prometheus` for the metrics in `datadog.metrics`.
- Ingress: an ALB of the cluster's class `ingress.className` (`alb-internet-facing` or
  `alb-internal`, which set the scheme and the certificate), HTTPS only, health-checked on the
  readiness endpoint.
- Network policy: in from the VPC (`vpcCidr`: the load balancer, which sends straight to the pods)
  to the HTTP and management ports; out to `egressPorts` inside the VPC, the in-cluster services
  in `egressNamespaces`, the node's Datadog agent (8126/TCP, 8125/UDP) and the node-local DNS
  (`clusterDnsIp`).
- What the cluster and AWS must provide for it is listed in [AWS.md](AWS.md).

## Workflows

Reusable workflows the services call with `uses: shortly-org/infra/.github/workflows/<file>@vX.Y.Z`
(replace `shortly-org` with the GitHub organisation; if this repository is private, its Actions
settings must allow access from the organisation's repositories):

- `code-quality.yml`: gitleaks, `spotlessCheck build` (unit and integration tests, JaCoCo),
  test reports.
- `deploy-service.yml` (inputs `service`, `chart-version`; on the caller's published release):
  validate the tag → build the image → Trivy → push → SBOM + cosign → `helm upgrade --install
  --atomic` of the chart → the service's own `.github/smoke-test.sh` (a failure rolls the release
  back), in the same job so the `production` environment asks for one approval.

They run in the calling repository: its variables (`AWS_REGION`, `ECR_REGISTRY`,
`AWS_ECR_PUSH_ROLE_ARN`), its `production` environment (`AWS_DEPLOY_ROLE_ARN`, `EKS_CLUSTER_NAME`,
required reviewers). They need no secrets.

## Release

Publishing a GitHub Release (tag `vX.Y.Z`) packages the chart as version `X.Y.Z` and pushes it to
`oci://$ECR_REGISTRY/charts/shortly-service`; the same tag is what services pin the workflows to.
A service moves to a new release by bumping both in its `deploy.yaml` (`@vX.Y.Z` and
`chart-version: X.Y.Z`), so an `infra` change reaches a service only when it does.

`chart.yaml` lints the chart on every pull request and on main. Repository variables:
`AWS_REGION`, `ECR_REGISTRY`, `AWS_ECR_PUSH_ROLE_ARN` (OIDC, no static keys). The ECR repository
`charts/shortly-service`, and pull access for each service's deploy role, are listed in
[AWS.md](AWS.md).

Check a service's values against the chart without a cluster, from the service's directory:

```bash
helm template dashboard-service ../infra/charts/shortly-service --values charts/values.production.yaml \
  --set image.repository=x --set image.digest=sha256:0
```

# What AWS provides

Nothing in these repositories creates AWS resources. This is what the production environment
must provide, under the names the chart, the services' values and the workflows use. The values
below are placeholders: account `123456789012`, region `eu-central-1`, GitHub organisation
`shortly-org`, domain `shortly.internal`.

## Network and DNS

- A VPC `10.0.0.0/16` (the chart's `vpcCidr`) over three availability zones: private subnets for
  the cluster, the databases and Kafka; public subnets for the redirect's load balancer; NAT for
  outbound traffic. Load balancers find their subnets by tag: `kubernetes.io/role/elb=1` on the
  public ones, `kubernetes.io/role/internal-elb=1` on the private ones.
- A private Route 53 zone `shortly.internal` on the VPC, holding:

  | Name | Points at |
  |---|---|
  | `shortly-production-writer`, `shortly-production-reader` | the Aurora cluster and reader endpoints (CNAME) |
  | `shortly.internal` | the CloudFront distribution (alias) |
  | `origin.shortly.internal` | the redirect's load balancer |
  | `dashboard.shortly.internal` | the dashboard's load balancer |
  | `login.shortly.internal` | Keycloak's load balancer |

  The load balancer records follow the Ingress hosts, so ExternalDNS keeps them (see below).
- Certificates in ACM: `shortly.internal` and `*.shortly.internal` for the load balancers, and
  `shortly.internal` in `us-east-1` for CloudFront. CloudFront connects only to an origin with a
  publicly trusted certificate, and visitors reach only public names, which `.internal` cannot
  have: a real deployment uses a domain of its own with a public zone in place of
  `shortly.internal`.
- CloudFront in front of the redirect: its origin is `origin.shortly.internal` over HTTPS, with an
  origin request policy that forwards `CloudFront-Viewer-Country` (the click's country comes from
  it), origin connection timeout 3 s with 3 attempts. Allowed methods GET and HEAD only (the
  default). CloudFront retries only failed connections, never a `5xx` from the origin; inside the
  region, the readiness probe and the load balancer's 5-second health checks take a failing pod
  out within about 10 s. Viewer protocol policy "Redirect HTTP to HTTPS", and a response headers policy that adds
  `Strict-Transport-Security: max-age=31536000; includeSubDomains`, so visitors only ever reach the
  redirect over TLS.
- AWS WAF: a regional web ACL with a per-IP rate-based rule on the `alb-internal` load balancer,
  which limits request floods on the dashboard's API.

## Kubernetes: one EKS cluster

- EKS in Auto Mode (AWS runs the nodes and their scaling, the load balancers, the VPC CNI and
  CoreDNS), Kubernetes 1.37, its name in the GitHub variable `EKS_CLUSTER_NAME`. The API endpoint
  is public, because GitHub-hosted runners deploy through it.
- Service CIDR `172.20.0.0/16`: Auto Mode serves DNS from every node at `172.20.0.10`, which the
  chart's network policy allows (`clusterDnsIp`).
- Network policies enforced: the ConfigMap `amazon-vpc-cni` in `kube-system` with
  `enable-network-policy-controller: "true"`.
- A node pool for the redirect, labelled and tainted `shortly.example/pool=redirect:NoSchedule`,
  amd64 instances (the images are built for amd64). Everything else runs on the built-in
  `general-purpose` pool.
- Two IngressClasses (controller `eks.amazonaws.com/alb`), each with IngressClassParams naming the
  scheme, one `group.name` (one load balancer per class), the certificate and the TLS 1.3 policy
  `ELBSecurityPolicy-TLS13-1-2-2021-06`:
  - `alb-internet-facing`: the redirect. Its IngressClassParams also set `prefixListsIDs` to the
    `com.amazonaws.global.cloudfront.origin-facing` prefix list, so only CloudFront reaches it;
  - `alb-internal`: the dashboard and Keycloak.
- The namespace `shortly`, where the services are released. The GitHub deploy role's access entry
  maps it to a group bound to the `admin` ClusterRole in `shortly` only. The namespace carries the
  label `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`, so a rollout waits until the load
  balancer sends to the new pod (verify on the cluster that Auto Mode honours it).
- An admission policy (Kyverno or the Sigstore policy-controller) that admits into `shortly` only
  images signed by the identity
  `https://github.com/shortly-org/infra/.github/workflows/deploy-service.yml@refs/tags/v*`,
  issuer `https://token.actions.githubusercontent.com`.

### Running alongside the services

| Component | What it does here |
|---|---|
| External Secrets Operator 0.16 or later (the chart uses `external-secrets.io/v1`) | turns the services' ExternalSecrets into Secrets, through a ClusterSecretStore `aws-secrets-manager` (Secrets Manager; EKS Pod Identity allowed `GetSecretValue` on `shortly/production/*`) |
| Reloader | restarts a Deployment when one of its Secrets changes |
| ExternalDNS | writes the Ingress hosts into the private zone (Pod Identity allowed to change that zone) |
| Datadog agent and Cluster Agent | traces on host port 8126, DogStatsD on host port 8125, the OpenMetrics checks from the pods' annotations, container logs; tolerates the redirect's taint. Datadog's AWS integration collects the load balancers' CloudWatch metrics; a monitor alerts when the redirect load balancer's `TargetResponseTime` p99 exceeds 50 ms (its `HTTPCode_Target_4XX/5XX_Count` give the status counts) |
| Keycloak 26 | the realm `shortly` of `local/keycloak/shortly-realm.json`, except: redirect and post-logout URIs `https://dashboard.shortly.internal/*`, `sslRequired: external`, display name `Shortly`, no demo users, no password grant. Served at `https://login.shortly.internal` through `alb-internal`; in the namespace `keycloak`; the dashboard fetches the signing keys from that same HTTPS address (no `KEYCLOAK_INTERNAL_URL` in production; the dashboard refuses to start with a non-HTTPS keys URL, and its network policy allows port 443). Its own database `keycloak` on Aurora |

## Data

- **Aurora PostgreSQL 17**: a writer and at least two readers in different availability zones behind the reader endpoint (with a single reader, its failure makes every uncached link answer `503`), database `shortly`, encrypted, reachable on 5432
  from the VPC. The services verify its certificate (`sslmode=verify-full`) against the RDS bundle
  baked into their images. A Datadog monitor alerts when `AuroraReplicaLag` exceeds 1 s: beyond
  5 s, a deactivated link evicted from a redirect's cache can be reloaded as still active.
- **Database roles**, as each service's `local/database-roles.sql` creates them locally (the
  dashboard's migrations grant the rest):

  | Role | |
  |---|---|
  | `dashboard_owner` | owns the database `shortly`; Flyway logs in as it |
  | `dashboard_app` | the dashboard's application login |
  | `link_reader` | no login; may read the published `link_snapshot` view |
  | `redirect_reader` | login, `CONNECTION LIMIT 64`, member of `link_reader` |

- **Amazon MSK** (Kafka 3.9): three brokers, TLS and SASL/SCRAM on 9096, reachable from the VPC,
  `auto.create.topics.enable=false`, replication factor 3, `min.insync.replicas=2`. SCRAM logins
  (secrets named `AmazonMSK_*`, encrypted with a customer managed KMS key): one for the dashboard
  (consumer group `shortly-stats`), one for the redirect (producer), one admin for topics.
  Cluster configuration `allow.everyone.if.no.acl.found=false`, and ACLs per login:

  | Login | Allowed |
  |---|---|
  | redirect | Write, Describe on topic `clicks` |
  | dashboard | Read, Describe on topic `clicks`; Read on consumer group `shortly-stats` |
  | admin | Create, Describe on the cluster (creates the topics) |
- **The topic `clicks`**: 6 partitions, replication factor 3, kept 7 days.

## Secrets Manager

What the services' ExternalSecrets read (each a JSON object):

| Secret | Properties |
|---|---|
| `shortly/production/dashboard-service/database` | `username` (`dashboard_app`), `password` |
| `shortly/production/dashboard-service/database-migration` | `username` (`dashboard_owner`), `password` |
| `shortly/production/dashboard-service/kafka` | `bootstrap_servers` (MSK's SASL/SCRAM brokers, under MSK's own names, which its certificates carry), `jaas_config` (`ScramLoginModule` for the dashboard's login) |
| `shortly/production/redirect-service/database` | `username` (`redirect_reader`), `password` |
| `shortly/production/redirect-service/kafka` | `bootstrap_servers`, `jaas_config` (`ScramLoginModule` for the redirect's login) |

## Images and the chart

ECR repositories `shortly/dashboard-service`, `shortly/redirect-service` and
`charts/shortly-service`: immutable tags, scanned on push. Their registry is the GitHub variable
`ECR_REGISTRY`.

## GitHub Actions

AWS access is OIDC (provider `token.actions.githubusercontent.com`), no stored keys.

| Role | Assumable by | Allowed to |
|---|---|---|
| `AWS_ECR_PUSH_ROLE_ARN`, one per repository | `repo:shortly-org/<repo>:ref:refs/tags/v*` only (releases) | push and pull that repository's own ECR repository: `shortly/<service>`, or `charts/shortly-service` for `infra` |
| `AWS_DEPLOY_ROLE_ARN` | `repo:shortly-org/<service>:environment:production` only | `eks:DescribeCluster`, pull the chart; in the cluster, `admin` in `shortly` |

Repository variables `AWS_REGION`, `ECR_REGISTRY`, `AWS_ECR_PUSH_ROLE_ARN`; the `production`
environment holds `AWS_DEPLOY_ROLE_ARN`, `EKS_CLUSTER_NAME` and the required reviewers.

On a fresh environment, release dashboard-service before redirect-service: the redirect becomes
ready only after reading `link_snapshot`, which the dashboard's migrations create.

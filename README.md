# ocp-microservices

Practice project: deploying the classic **Sock Shop** microservices demo app
to **OpenShift** (Red Hat Developer Sandbox) using **GitHub Actions** for CI
and plain `oc apply` for CD (ArgoCD/GitOps was investigated but isn't
available on the free Sandbox tier — see [Known limitations](#known-limitations)).

## Architecture

14 components, all deployed into a single namespace:

| Component | Language/Image | Built by us? | Notes |
|---|---|---|---|
| front-end | Node.js | yes | public entrypoint, has the Route |
| catalogue | Go | yes | real `/health` endpoint |
| catalogue-db | MySQL 5.7 (custom seed) | yes | seeded via `dump.sql` |
| carts | Java/Spring Boot 2.0.4 | yes | patched (see below) |
| carts-db | `bitnami/mongodb:latest` | no | stock image |
| orders | Java/Spring Boot 1.4.4 | yes | |
| orders-db | `bitnami/mongodb:latest` | no | stock image |
| shipping | Java/Spring Boot 1.4.0 | yes | |
| payment | Go | yes | real `/health` endpoint |
| user | Go | yes | real `/health` endpoint |
| user-db | `quay.io/mongodb/mongodb-community-server:4.4.29-ubi8` | no | pinned old version, see below |
| queue-master | Java/Spring Boot 1.4.0 | yes | patched (see below) |
| rabbitmq | `rabbitmq:3.9-management` | no | stock image |
| session-db | `redis:alpine` | no | stock image |

The 8 app services (`front-end`, `catalogue`, `carts`, `orders`, `shipping`,
`payment`, `user`, `queue-master`) are vendored as **git submodules** from
the original (now archived) [`microservices-demo`](https://github.com/microservices-demo)
GitHub org — their real upstream source, unmodified where possible.

## Repo layout

```
services/          git submodules (upstream app source, read-only)
docker/            Dockerfile/pom.xml/source overrides for the 2-3 services
                   whose submodule content needed a real fix (see below) --
                   these get spliced into the build by CI, since we can't
                   push changes into a submodule's own upstream repo
k8s/<service>/     Deployment + Service (+ Route for front-end) per component
.github/workflows/build-push.yml   CI: builds & pushes all 9 custom images
```

## Prerequisites

- `oc`, `gh`, `kustomize` CLIs (`brew install openshift-cli gh kustomize`)
- A GitHub repo with **Settings → Actions → General → Workflow permissions**
  set to "Read and write" (lets the built-in `GITHUB_TOKEN` push to GHCR)
- A Red Hat Developer Sandbox namespace (or any OpenShift namespace you're
  admin of), logged in locally via `oc login`

## Setup from scratch

```bash
git clone --recurse-submodules <this-repo>
cd ocp-microservices
gh auth login && gh auth setup-git
oc login --token=... --server=...
```

## CI/CD pipeline

Push a version tag to build and push all 9 images:

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/build-push.yml` runs a matrix build over all 9 custom
images, tags each `ghcr.io/<owner>/ocp-microservices-<name>:<version>`
(stripped from the git tag), and pushes to GHCR. Bump the version in both
the git tag and every `k8s/*/deployment.yaml` image reference together —
this project uses manual semver, not `:latest`.

GHCR packages are private by default; either make them public (Packages tab
on your GitHub profile) or create an `imagePullSecret` and link it to the
namespace's `default` service account:

```bash
oc create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT> \
  -n <namespace>
oc secrets link default ghcr-pull-secret --for=pull -n <namespace>
```

## Deploying

```bash
oc apply -R -f k8s/ -n <namespace>
```

If you've redeployed a few times and see stuck rollouts (old ReplicaSet
never replaced), do a clean sweep instead of chasing it:

```bash
oc delete deployment --all -n <namespace>
oc apply -R -f k8s/ -n <namespace>
```

## Real issues hit & fixed (worth reading before you redo this)

This is 8-10 year old code being rebuilt and deployed today. Nearly every
failure was a real bug, not a config typo — worth knowing about in advance:

1. **Dead base image**: `java:openjdk-8-alpine` was removed from Docker Hub
   entirely. Fixed by swapping to `eclipse-temurin:8-jre-alpine` in
   `docker/carts/Dockerfile` and `docker/queue-master/Dockerfile` (the
   originals, still in the submodules, are untouched).
2. **Missing Maven build step**: the Java services' Dockerfiles assume a
   pre-built `target/*.jar` exists (`COPY target/*.jar`) — CI has to run
   `mvn package` before `docker build`, which the original repo's own CI
   handled outside the Dockerfile.
3. **Broken build context**: `catalogue-db`'s Dockerfile does
   `COPY ./data/dump.sql`, which only resolves if the Docker build context
   is set to its own subdirectory, not the repo root.
4. **Submodule `.git` breaks legacy tooling**: `catalogue`/`payment` use the
   pre-Go-modules `gvt` tool, which runs `git` commands internally. A
   submodule's `.git` is a one-line **gitlink file** pointing at a path that
   doesn't exist inside the Docker build context — git hard-fails on *any*
   command when it finds a broken gitlink (not when there's no `.git` at
   all). Fix: `rm -f <context>/.git` before building.
5. **Real Spring Boot 2.0 incompatibility** (`carts`): the upstream pom pins
   `spring-cloud-starter-zipkin:1.1.0.RELEASE` (pre-Boot-2.0) alongside
   `spring-boot-starter-parent:2.0.4.RELEASE` — a `NoSuchMethodError` on
   `SpringApplicationBuilder`. Worse: `io.prometheus:simpleclient_spring_boot`
   depends on `AbstractEndpoint`, a class Spring Boot 2.0 deleted entirely as
   part of its actuator rewrite — no dependency version fixes that, since
   the class is just gone. Both were removed; a plain `io.prometheus:simpleclient`
   Histogram (used directly in `HTTPMonitoringInterceptor`) still works fine.
6. **`JpaHelper` NoSuchBeanDefinitionException** (`carts`): this Mongo-backed
   app autowires a JPA-specific Spring Data REST bean as required, which
   isn't guaranteed to exist with today's dependency resolution. Made it
   `@Autowired(required = false)`.
7. **JVM heap sizing**: the old JDK8 builds here predate reliable
   cgroup-aware default heap sizing — without an explicit `-Xmx`, they were
   sizing off the *node's* total memory rather than the container's limit,
   getting OOMKilled well under whatever limit was set. Fix: explicit
   `-Xmx`/`JAVA_OPTS` on every JVM service.
8. **Dead `setcap` step** (`queue-master`): the original Dockerfile grants
   `cap_net_bind_service` so java can bind port 80 as non-root. We moved to
   port 8080 instead (no privileged-port issue), but OpenShift's
   `no_new_privs` enforcement actively blocks *executing* a binary that
   carries a leftover file capability — had to remove the step entirely,
   not just stop relying on it.
9. **`mongo` (any tag) blocked**: this specific Sandbox cluster transparently
   rewrites all `docker.io/library/mongo` pulls through an internal mirror
   that 403s ("bad credentials") — confirmed identical failure across
   several tags, not fixable from inside the namespace. `bitnami/mongodb`
   isn't subject to that rewrite.
10. **Mongo driver/server version gap** (`user`): `user`'s ~2017-era Go
    `mgo` driver can't handshake with MongoDB 8.x (bitnami's `:latest`,
    since bitnami's free tier no longer publishes *any* older version tag).
    Fixed by switching just `user-db` to
    `quay.io/mongodb/mongodb-community-server:4.4.29-ubi8`, a real official
    image with actual pinned old versions available.
11. **`anyuid` SCC can't be granted**: a Sandbox namespace-admin can't grant
    an SCC they don't hold themselves (standard RBAC escalation
    prevention) — so a `RoleBinding` to `anyuid` always fails here. Turned
    out to be unnecessary anyway: all the stock datastore images ran fine
    under the default restricted SCC. Where a volume genuinely needs to be
    writable under an arbitrary UID (`user-db`'s `/data/db`), the fix is an
    `emptyDir` volume + omitting `fsGroup` (let OpenShift auto-assign one
    from the namespace's allowed range — a hardcoded value gets rejected).
12. **Probe timing**: these old Spring Boot apps have genuinely slow cold
    starts (one bean-init step alone logged 53 seconds) — default/short
    `initialDelaySeconds` values kill them mid-boot in an endless crash
    loop that has nothing to do with the app itself. `orders`/`shipping`
    ended up needing 100s readiness / 180s liveness delays.

## Known limitations

- **No ArgoCD/GitOps**: the free Developer Sandbox doesn't have the
  OpenShift GitOps operator installed, and a namespace-admin can't install
  cluster-scoped operators or CRDs themselves. Deploys are via plain
  `oc apply`. Revisit this on a cluster where you have (or can get)
  cluster-admin, e.g. OpenShift Local (CRC).
- **Public Route returns 503**: confirmed via a from-scratch nginx
  pod+service+route test that this is a cluster-wide router issue on this
  specific Sandbox instance, not anything in this project's config — every
  layer we can inspect (Service, Endpoint, Pod, Route admission,
  NetworkPolicy) is correct, and the app works perfectly when called from
  inside the cluster. Not fixable from a namespace-scoped user; retry later
  or check Red Hat's Sandbox status.
- **`user-db` has no seed data**: the original demo's `weaveworksdemos/user-db`
  image (pre-loaded with sample users) isn't in any of the 8 vendored
  repos — it lived in a separate, unlisted one. Register test users through
  the app instead of expecting demo accounts.

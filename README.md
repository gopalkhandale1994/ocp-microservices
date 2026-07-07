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
docker/            Dockerfile/pom.xml/source overrides for the services
                   whose submodule content needed a real fix (see below) --
                   these get spliced into the build by CI, since we can't
                   push changes into a submodule's own upstream repo
k8s/<service>/     Deployment + Service (+ Route for front-end) per component
test/              e2e test scripts + the manifest validator, all runnable
                   locally or as CI pipeline stages (see Testing, below)
.github/workflows/build.yml    validate -> unit-test -> build-and-push
.github/workflows/deploy.yml   deploy -> smoke-test (auto-runs after build.yml,
                                also independently re-runnable, see CI/CD pipeline)
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

GHCR packages are private by default; either make them public (Packages tab
on your GitHub profile) or create an `imagePullSecret` and link it to the
namespace's `default` service account:

```bash
oc create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT> \
  -n <namespace>
oc secrets link default ghcr-pull-secret --for=pull -n <namespace>
```

For the pipeline's deploy/smoke-test stages, CI needs its own OpenShift
credentials — **not** your personal `oc login` token (too short-lived, and
too broad a grant for a robot). Create a dedicated service account scoped
to just this namespace instead:

```bash
oc create serviceaccount github-ci -n <namespace>
oc policy add-role-to-user edit -z github-ci -n <namespace>

TOKEN=$(oc create token github-ci -n <namespace> --duration=8760h)
SERVER=$(oc whoami --show-server)
echo "$TOKEN" | gh secret set OC_TOKEN --repo <owner>/<repo>
gh secret set OC_SERVER --repo <owner>/<repo> --body "$SERVER"
gh variable set OC_NAMESPACE --repo <owner>/<repo> --body "<namespace>"
unset TOKEN
```

## CI/CD pipeline

Two separate workflows, not one — rebuilding all 9 images every time you
want to tweak a `k8s/` manifest or a deploy step is a waste of ~10 minutes.
Push a version tag to kick off the whole chain:

```bash
git tag v0.1.0
git push origin v0.1.0
```

**`build.yml`** (validate → unit-test → build-and-push):
1. **validate** — `test/validate_manifests.py` sanity-checks every file
   under `k8s/` (valid YAML, has `apiVersion`/`kind`/`metadata.name`). Pure
   static check, no cluster credentials touched.
2. **unit-test** — runs the real `mvn test` suite for the four Java
   services (`carts`, `orders`, `shipping`, `queue-master`), applying the
   same pom/source overrides the build stage uses. A real test failure
   blocks the pipeline here, before anything gets built.
3. **build-and-push** — matrix build over all 9 custom images, tagged
   `ghcr.io/<owner>/ocp-microservices-<name>:<version>` (stripped from the
   git tag) and pushed to GHCR. Bump the version in both the git tag and
   every `k8s/*/deployment.yaml` image reference together — this project
   uses manual semver, not `:latest`.

**`deploy.yml`** (deploy → smoke-test) — triggers automatically once
`build.yml` succeeds (via a `workflow_run` trigger, checking out the exact
commit that was built):
4. **deploy** — logs in as the `github-ci` service account and runs
   `oc apply -R -f k8s/`, then waits on every Deployment's rollout status.
5. **smoke-test** — runs `test/e2e-test.sh` (all 14 services reachable and
   healthy) and `test/e2e-order-flow.sh` (a full register → login → add to
   cart → place order journey, verified directly against `orders-db`/
   `user-db`, not just trusted from the API response) against the
   just-deployed namespace.

`deploy.yml` can *also* be triggered on its own — Actions tab → Deploy →
Run workflow — to re-apply manifests and re-run the smoke tests against
whatever was last built, without touching `build.yml` at all. That's the
one to use when you're iterating on a `k8s/*.yaml` change or a bug in the
deploy/smoke-test steps themselves.

## Testing

Both e2e scripts run from your own machine exactly the same way CI runs
them — they operate entirely inside the cluster (via throwaway pods), so
they aren't affected by the Route/router issue described below.

```bash
./test/e2e-test.sh <namespace>          # all 14 services: readiness + real /health checks
./test/e2e-order-flow.sh <namespace>    # register, login, add to cart, place an order,
                                         # then confirm the documents landed in orders-db/user-db
```

## Deploying manually

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
13. **Same Mongo driver/version gap, different service** (`orders`): all 14
    pods reporting healthy and TCP-reachable did *not* mean writes worked —
    `orders-db` (also `bitnami/mongodb:latest`) rejected every insert from
    `orders` with `Unsupported OP_QUERY command: insert` (code 352).
    `orders` runs 2016-era Spring Boot 1.4.4, whose Mongo driver still
    issues legacy `OP_QUERY` opcodes that MongoDB removed entirely in 5.1+;
    `carts` (Spring Boot 2.0.4, a modern driver) was never affected — this
    only surfaced once `test/e2e-order-flow.sh` actually exercised a write,
    not just a connection. Same fix as `user-db`: switched to
    `quay.io/mongodb/mongodb-community-server:4.4.29-ubi8`.
14. **A single bad response could crash all of front-end**: `POST /orders`
    checked `body.status_code === 500` on the raw response *string*, before
    `JSON.parse` — always false (strings don't have that property), so it
    was dead code. Any error response from `user` (no `_links` field at
    all) fell through to `jsonBody._links.customer.href` and threw an
    uncaught `TypeError`, which crashes the entire Node process — no
    per-request isolation, so one bad request took down front-end for every
    user. Sibling handlers in the same file (`/card`, `/address`) already
    guarded this correctly; this one didn't. Fixed via a source overlay
    (`docker/front-end/src-override`) that parses first, then checks.

## Known limitations

- **No ArgoCD/GitOps**: the free Developer Sandbox doesn't have the
  OpenShift GitOps operator installed, and a namespace-admin can't install
  cluster-scoped operators or CRDs themselves. Deploys are via plain
  `oc apply`. Revisit this on a cluster where you have (or can get)
  cluster-admin, e.g. OpenShift Local (CRC).
- **Public Route returns 503**: not this project's config — every layer we
  can inspect (Service, EndpointSlice, Pod, Route admission, NetworkPolicy)
  is correct, and the app works perfectly when called from inside the
  cluster (that's exactly what the e2e tests do, which is why they aren't
  affected). Confirmed via a from-scratch nginx pod+service+route test that
  hits the identical 503 — re-confirmed days later, same result. The more
  precise finding: the platform's own console route (same router, same
  `apps.` domain) works fine, so it's not the whole router down — it's
  specific to tenant-created routes on this cluster shard, likely an
  `IngressController` namespace/route selector that isn't picking up tenant
  namespaces correctly. Not something a namespace-scoped user can inspect
  or fix (`IngressController` objects live in `openshift-ingress-operator`).
  Rather than chase a platform bug, view the app in a browser via
  port-forward instead:
  ```bash
  oc port-forward svc/front-end 8080:80 -n <namespace>
  # then open http://localhost:8080
  ```
- **`user-db` has no seed data**: the original demo's `weaveworksdemos/user-db`
  image (pre-loaded with sample users) isn't in any of the 8 vendored
  repos — it lived in a separate, unlisted one. Register test users through
  the app instead of expecting demo accounts.

## Security notes (read before reusing any of this elsewhere)

- **Licensing**: all 8 vendored services (`services/*`) are Apache License
  2.0 — permissive, safe for internal use/modification. LICENSE files are
  intact in each submodule; don't strip them if you copy code out.
- **This is a practice deployment, not a production template.** A few
  things here are *intentionally* insecure because they only ever run
  inside a private, single-user Sandbox namespace with no real user data:
  `catalogue-db`'s `MYSQL_ROOT_PASSWORD=fake_password` and
  `carts-db`'s `ALLOW_EMPTY_PASSWORD=yes` are both literally what they say —
  don't carry either pattern into anything that isn't a disposable
  practice cluster.
- **Dependency age**: the vendored services run 8-10 year old framework
  versions (Spring Boot 1.4.x/2.0.4, Node 10-era front-end deps, pre-Go-modules
  Go). These almost certainly have known CVEs in their dependency chains —
  that's *why* rebuilding this today surfaced so many real bugs (see the
  numbered list above). GitHub Dependabot alerts are enabled on this repo,
  so check the Security tab before assuming anything here is current.
- **No malicious code found.** Checked for remote-download-and-execute
  patterns, unexpected outbound network calls, and obfuscated/eval-based
  code across the vendored source — nothing outside well-known vendored
  front-end libraries (jQuery, etc.) and one dead-code path worth knowing
  about: `queue-master`'s `DockerSpawner.java` can spawn arbitrary Docker
  containers via the Docker API, but its only caller has those calls
  commented out (confirmed dead, not reachable in normal operation).
- **CI credentials are least-privilege**: `github-ci` (used by
  `deploy.yml`) is bound to a custom `Role` (`k8s/rbac/ci-deployer-role.yaml`)
  scoped to exactly the resources the pipeline touches — not OpenShift's
  built-in `edit` role, which would also grant it read/write on every
  Secret in the namespace.
- **Automated SAST scan (CodeQL)**: `.github/workflows/codeql.yml` runs
  GitHub's CodeQL scanner across JS, Go, and Java on every push to `main`
  and weekly — results live in the repo's Security tab, not just this file.
  First run found 50 alerts, effectively all inside the vendored 2016-era
  demo app itself, not in anything written for this deployment:
  - **Critical**: 12 SSRF findings in `front-end`'s `api/user`, `api/cart`,
    and `helpers/index.js` — internal calls to other services built from
    request data without validating the target.
  - **High**: reflected XSS in `shipping`'s `ShippingController.java`, weak
    password hashing in `user/api/service.go`, no CSRF middleware on
    `front-end/server.js`'s session cookie, clear-text logging of session
    data in `public/js/client.js`, and a DOM-XSS bug in the vendored
    `jquery.flexslider.js` library.
  - **Medium**: Spring Boot actuators left exposed in `shipping`'s and
    `queue-master`'s `pom.xml`, an open redirect in `front-end/helpers/index.js`,
    session cookie sent without `Secure`, plus ~20 more findings inside
    `jquery.flexslider.js` (an unmaintained third-party plugin, not
    project code).
  None of this was introduced by the OpenShift/CI work in this repo — it's
  what a real static scan finds in an 8-10 year old demo app once you
  point one at it. Treat the Security tab as the live source of truth;
  this bullet is a snapshot, not a promise it stays accurate.

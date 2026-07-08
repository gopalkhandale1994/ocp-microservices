# ocp-microservices

Deploy the **Sock Shop** microservices demo app to **OpenShift** using
**GitHub Actions** for CI/CD. Vendored app source, unmodified; the
`k8s/`, `docker/`, and `.github/workflows/` in this repo are the DevOps
layer on top of it.

## What's in this repo

```
services/          git submodules -- upstream app source, unmodified
docker/            our own Dockerfiles for the 2 services whose submodule
                   doesn't ship a working one (carts, queue-master)
k8s/<service>/     Deployment + Service (+ Route for front-end), one per
                   component, plus k8s/rbac/ for the CI service account
.github/workflows/build.yml    unit-test -> build-and-push -> trivy-scan
.github/workflows/deploy.yml   deploy (auto-runs after build.yml succeeds,
                                or run it on its own any time)
```

## Prerequisites

- `oc`, `gh` CLIs installed and on your PATH
- An OpenShift namespace you're admin of (e.g. a Red Hat Developer
  Sandbox namespace), and `oc login` working locally
- A GitHub repo with **Settings → Actions → General → Workflow
  permissions** set to "Read and write" (lets the built-in
  `GITHUB_TOKEN` push images to GHCR)

## 1. Clone

```bash
git clone --recurse-submodules <this-repo>
cd ocp-microservices
```

## 2. Make the images pullable

GHCR packages are private by default. Either make each
`ocp-microservices-*` package public after the first push (Packages tab
on your GitHub profile), or create a pull secret and link it to the
namespace's `default` service account:

```bash
oc create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=<github-user> --docker-password=<PAT> \
  -n <namespace>
oc secrets link default ghcr-pull-secret --for=pull -n <namespace>
```

## 3. Create the CI service account

CI needs its own OpenShift credentials, scoped to just this namespace --
not your personal `oc login` token.

```bash
oc create serviceaccount github-ci -n <namespace>

# Least-privilege Role, applied once -- not part of the routine deploy
# (github-ci intentionally can't manage its own Role/RoleBinding)
oc apply -f k8s/rbac/ci-deployer-role.yaml -n <namespace>

TOKEN=$(oc create token github-ci -n <namespace> --duration=8760h)
SERVER=$(oc whoami --show-server)
```

## 4. Configure GitHub secrets/variables

```bash
echo "$TOKEN" | gh secret set OC_TOKEN --repo <owner>/<repo>
gh secret set OC_SERVER --repo <owner>/<repo> --body "$SERVER"
gh variable set OC_NAMESPACE --repo <owner>/<repo> --body "<namespace>"
unset TOKEN
```

## 5. Run the pipeline

```bash
git tag v0.1.0
git push origin v0.1.0
```

This triggers **Build** (`unit-test` → `build-and-push` → `trivy-scan`),
which pushes all 9 images to
`ghcr.io/<owner>/ocp-microservices-<name>:0.1.0`. **Deploy** then runs
automatically, applying `k8s/` and waiting for every rollout --
*but only if you're pushing to your repo's default branch*. GitHub only
auto-fires a `workflow_run`-triggered workflow using the copy of it that
lives on the default branch, regardless of which branch actually built.
Working on another branch: either set it as the repo's default, or after
Build finishes, trigger Deploy yourself (Actions tab → Deploy → Run
workflow).

To change versions later, bump the tag *and* every
`k8s/*/deployment.yaml` image reference together (manual semver, not
`:latest`), then repeat this step.

`Deploy` can also be re-run on its own (Actions tab → Deploy → Run
workflow) to re-apply `k8s/` without rebuilding any images -- useful when
you're only changing a manifest.

## 6. Access the app

```bash
oc port-forward svc/front-end 8080:80 -n <namespace>
# open http://localhost:8080
```

If your cluster's public Route works, `oc get route front-end -n
<namespace>` gives you a URL directly instead. On some Sandbox-tier
clusters, tenant Routes 503 regardless of app health (a platform-side
Ingress issue, not fixable from inside the namespace) -- port-forward
always works since it bypasses the Route entirely.

## Known, unpatched upstream bugs

This app's source is never modified, so these ship as-is:

- **`carts` fails to boot.** Its vendored `pom.xml` pins
  `spring-cloud-starter-zipkin:1.1.0.RELEASE` against
  `spring-boot-starter-parent:2.0.4.RELEASE`, throwing
  `NoSuchMethodError` on `SpringApplicationBuilder` at startup. Debugging
  and fixing this is a good first exercise.
- **`front-end` can crash on one bad response shape.** `POST /orders`
  checks `body.status_code === 500` on the raw response string, before
  `JSON.parse` -- always false. An error response from `user` with no
  `_links` field throws an uncaught `TypeError` that crashes the whole
  Node process.
- **No seed data in `user-db`.** Register test users through the app.

## License

The 8 vendored services under `services/*` are each Apache License 2.0,
with their own `LICENSE` file intact in every submodule -- unmodified,
so no changes to attribute. This repo's own files (`k8s/`, `docker/`,
`.github/workflows/`) are the DevOps layer written for this deployment.

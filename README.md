# Hardening policy gate for Harness CD

This repository answers the three asks from the call, using a single policy
document as the source of truth for all of them.

> **"Is there a way we can implement the same policy on the CD part?"** — Ramesh, 15:32
>
> **"…if there is a registry of vulnerable images, the application image, not even the base image… if the image is vulnerable, then we should not allow the deployment."** — Barath, 16:50
>
> **"Both combination will be best. One is the application container image itself… another approach will be based on the base image level."** — Ramesh, 17:37

Both checks, in one gate, driven by the **same policy** already enforced in CI.

---

## The core idea

The point is not that Harness can block a deployment. The point is that there is
**one source of truth** and **several enforcement points**:

```
        ┌─────────────────────────────────────────┐
        │   Base image hardening pipeline         │
        │   0 criticals  ->  PATCH the policy     │
        └────────────────┬────────────────────────┘
                         │  writes stable_base
                         ▼
        ┌─────────────────────────────────────────┐
        │   Policy in Harness Policy Management   │
        │   stable_base = 1.0.42                  │
        │   blocked_artifacts = [...]             │
        └──┬──────────────┬──────────────────┬────┘
           │ reads        │ reads            │ reads
           ▼              ▼                  ▼
    ┌────────────┐  ┌────────────┐  ┌──────────────────┐
    │ CI gate    │  │ CD gate    │  │ Mass deploy      │
    │ Dockerfile │  │ artifact   │  │ orchestrator     │
    │ (existing) │  │ + base     │  │ driver file      │
    └────────────┘  └────────────┘  └──────────────────┘
```

Nobody edits the stable version by hand. When the hardening pipeline publishes
`1.0.43`, every gate starts rejecting artifacts built on `1.0.42` **at that same
instant, without touching a single deployment pipeline.** With 100 applications
that is the difference between one change and one hundred.

---

## What the gate validates

| Rule | What it checks | Where it came from |
|---|---|---|
| **A1** | The artifact declares its base image (OCI label or annotation). If not, it **fails closed** | traceability, 18:14 |
| **A2** | The base image comes from an approved hardened repository | Ramesh, 17:37 |
| **A3** | The base image version is the current one (`stable_base.tag`) | the case already demoed in CI |
| **A4** | The digest matches, not just the tag — catches overwritten tags | *added, not requested* |
| **B1** | The application artifact is not on the denylist | Barath, 16:50 |
| **B2 / B3** | The artifact scan is within the critical / high thresholds | Barath, 17:00 |
| **C1** | Production requires a `change_number` | *added* — the driver file already carries it |
| **C2** | Production should carry `approval=required` — **warning only** | *added* — from `deploy_params` |

`A4`, `C1` and `C2` were not requested; they are value-add to offer during the
call. `C1` and `C2` are worth pointing out because they are derived from the
customer's own driver file: every `Prod` entry already has `change_number` and
`approval=required`, and no `Dev` or `Test` entry does. The rules formalise
something their file already satisfies, so they cost the customer nothing.

`C2` is deliberately a warning rather than a block. Promoting it is a four-line
move into the `deny` block — that is the customer's call, not ours.

---

## Repository layout

```
policies/hardened_image_cd.rego         The policy: the source of truth
  └─ managed stable_base block           rewritten by the hardening pipeline

pipelines/
  cd_deploy_policy_gate.yaml            Harness: gate stage + deploy stage
  cd_policy_gate_only.yaml              The gate alone, reusable, deploys nothing

driver/
  deployment_driver_file.yaml           The customer's file, verbatim
  demo_driver_file.yaml                 Same schema, tuned for the demo
  README.md                             How the file maps onto the gate

.github/workflows/
  build-and-deploy.yml                  Build + OCI labels + trigger Harness + poll
  harden-base-image.yml                 Build the base, scan it, PATCH stable_base
  mass-deploy.yml                       Driver file -> matrix -> gate per entry -> report
  policy-test.yml                       opa check + fmt + all scenarios on every PR

app/                                    Buildable application artifact
  Dockerfile                            ARG BASE_IMAGE — the version is NOT in here
  pom.xml, src/                         minimal Java service, no external deps

base/                                   Buildable hardened base image
  Dockerfile                            remediations + non-root user
  VERSION                               candidate version

k8s/                                    Manifests for the Harness service
  values.yaml, templates/               image = <+artifact.image>

scripts/                                One gate phase per script, all reusable
  fetch_policy.sh                       policy + stable_base (Harness or local)
  resolve_base_image.sh                 from a tag to its lineage, via crane
  scan_app_image.sh                     trivy with --exit-code 0 on purpose
  evaluate_gate.sh                      assembles the input, evaluates deny
  update_stable_base.sh                 PATCH the managed block, publish it
  driver_expand.py                      driver file -> flat list of deployment jobs
  mass_deploy.sh                        the orchestrator: gate per entry, one report
  bootstrap.sh                          replaces ghcr.io/OWNER with your owner

test/
  cases.sh                              15 assertions, deny and warn
  fixtures/*.json                       one input per scenario

Makefile                                make tools / test / check / gate / driver
docs/demo-runbook.md                    demo script and open verifications
```

---

## Getting started

```bash
# 1. Replace the registry placeholder with your GitHub owner
./scripts/bootstrap.sh <your-owner>

# 2. Local tooling and policy validation
make tools
make check

# 3. Publish the hardened base image
#    Actions -> harden-base-image -> Run workflow

# 4. Build the application artifact
#    Actions -> build-and-deploy -> Run workflow (skip_deploy = true the first time)

# 5. Build the "bad" artifact for the blocking demo
#    Actions -> build-and-deploy -> base_tag_override = 1.0.39
```

Steps 3 and 4 work without Harness: the workflow falls back to the policy in the
repository when `HARNESS_API_KEY` is absent, and the deploy job skips with a
warning. That lets you get the artifacts published and verified before wiring
anything up.

### Secrets

| GitHub secret | Used for |
|---|---|
| `GITHUB_TOKEN` | automatic; pushing to GHCR |
| `HARNESS_API_KEY` | fetching/publishing the policy, triggering CD |
| `HARNESS_ACCOUNT_ID`, `HARNESS_ORG_ID`, `HARNESS_PROJECT_ID` | account identifiers |

| Harness secret | Used for |
|---|---|
| `harness_api_key` | the gate fetches the policy |
| `artifact_registry_user` / `artifact_registry_token` | `crane` and `trivy` read the artifact |

With GHCR, `artifact_registry_user` is your GitHub username and the token is a
PAT with `read:packages`. GHCR packages are private by default: either make them
public or the PAT is mandatory.

---

## The prerequisite to negotiate with the customer

**The gate cannot work if the artifact does not declare its base image.** That is
the only work that falls on their side, and it is worth putting on the table with
all three options:

| Option | What it takes | When to pick it |
|---|---|---|
| **OCI labels** (recommended) | add `labels:` to `docker/build-push-action`; ~4 lines per repository | if they can touch the GHA workflow |
| **SBOM / SSCA** | Harness SSCA generates and signs the SBOM at build time; the gate queries it instead of reading labels | if they already plan to adopt SSCA — most robust, but adds scope |
| **JFrog properties** | a job stamps the base image as an artifact property in Artifactory | if they cannot touch the build at all |

The labels option has the least friction, and as a bonus the example workflow
**resolves the base image from the same policy at build time**, so the Dockerfile
no longer hardcodes the version:

```dockerfile
ARG BASE_IMAGE          # injected by the workflow, read from the policy
FROM ${BASE_IMAGE}
```

That removes the root cause of the problem demoed in CI: there is no longer any
need to block a developer for writing `1.0.39`, because the developer never
writes the version at all. **This is the strongest argument in the repository —
make it during the call.** The CI gate still earns its place as a safety net: it
catches anyone who hardcodes a `FROM` and bypasses the mechanism.

---

## Mass deploy, driven by the customer's driver file

`driver/deployment_driver_file.yaml` is the customer's actual file. Two things in
it shaped the design:

**1. Every entry names its own `pipeline_id` and `input_set_id`.** With 100 apps
there are 100 deployment pipelines, each with its own input set. Putting the gate
inside each one is a change in a hundred places. So the gate runs as a separate,
reusable pipeline (`cd_policy_gate_only`) that the orchestrator invokes once per
entry, and the customer's pipeline is called **unmodified** only if the gate
passes.

**2. `disable`, `change_number` and `deploy_params` are already there.** No new
fields had to be invented: `disable: true` is a per-entry kill switch,
`change_number` satisfies `C1`, `deploy_params` feeds `C2`.

```bash
# Evaluate the whole fleet without deploying anything
./scripts/mass_deploy.sh --driver driver/deployment_driver_file.yaml \
                         --group Dev \
                         --registry-prefix ghcr.io/<owner> \
                         --dry-run --no-scan
```

One report for the entire fleet:

```
ENTRY                      ARTIFACT                               VERDICT      RULES
Dev-app1-dev1              ghcr.io/OWNER/app1:v1.2                PASSED       -
Dev-app1-dev2              ghcr.io/OWNER/app1:v1.1-base1039       BLOCKED      A3
Dev-app2-dev3              ghcr.io/OWNER/app2:v1.5                BLOCKED      B1
Prod-app1-prod             ghcr.io/OWNER/app1:v1.2                PASSED       -
Prod-app4-prod             ghcr.io/OWNER/app4:v1.20               BLOCKED      A1 C1
```

If 50 of 100 applications were built on a withdrawn base image, that is 50 rows
in a single run instead of 50 pipelines failing one at a time. The same thing
runs as a GitHub Actions matrix — one entry per runner, in parallel — via
`.github/workflows/mass-deploy.yml`.

**One open question for the customer:** the driver file names the app (`app1`)
and its version (`v1.2`) but not the container image path. The orchestrator
builds the reference by convention, `${REGISTRY_PREFIX}/${name}:${version}`.
Either an optional `image_repo:` per entry or a top-level `registry_prefix:`
makes it explicit — both are already supported. See `driver/README.md`.

---

## How this connects to the linear pipeline ask

The gate becomes the first stage before each environment promotion. Dev, QA, UAT
and Prod all go through the same gate with a different `env_type`, and `C1` means
only Prod demands the change number. The polling step in `build-and-deploy.yml`
hands control back to GitHub Actions with the real deployment result, which is
what Anil asked for at 39:38 — no need to open the Harness console to find out
whether it passed.

The selling argument for all three asks is the same: enforcement scales because
the decision lives in one document, not replicated across N pipelines.

---

## Validating without Harness, without a registry, without a cluster

```bash
make tools
make test
```

| Scenario | Expected | Result |
|---|---|---|
| Compliant artifact | allowed | ✅ allowed |
| Base image `1.0.39` | blocked `[A3]` | ✅ blocked |
| Artifact on the denylist | blocked `[B1]` | ✅ blocked |
| No base image label | blocked `[A1]` | ✅ blocked |
| Prod, no change_number, 2 criticals | blocked `[B2] [B3] [C1]` | ✅ 3 violations |
| Exempt repository (sandbox) | allowed | ✅ allowed |
| Right tag, different digest | blocked `[A4]` | ✅ blocked |
| Prod compliant with change_number | allowed | ✅ allowed |
| `driver` Prod[0] app1/prod | allowed, no warnings | ✅ allowed |
| `driver` Prod without approval | allowed + `[C2]` warning | ✅ 1 warning |
| `driver` Dev app2/dev3 | blocked `[B1]` | ✅ blocked |

15 of 15 assertions pass on OPA 0.68.0, deny and warn rules included.

The full gate against a real, already published artifact:

```bash
make gate APP=ghcr.io/<owner>/app1:v20260813-abc1234
```

---

Demo script, environment tweaks and the verifications still open:
[`docs/demo-runbook.md`](docs/demo-runbook.md).

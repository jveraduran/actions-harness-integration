# Policy-gated CD — hardening enforcement before deployment

Answer to what Barath and Ramesh asked on the call (min 15:32 – 18:34):

> *"Is there a way we can implement the same policy on the CD part?"*
> *"…if there is a registry of vulnerable images, the application image, not even the base image… if the image is vulnerable, then we should not allow the deployment."*
> *"Both combination will be best. One is the application container image itself… another approach will be based on the base image level."*

Both checks are implemented. They live at two different points in the flow, each
reading its own policy from **Harness Policy Management** — so the rules are
versioned and auditable in Harness, not buried in pipeline YAML.

---

## What actually got built

```
  GitHub Actions — build job                    Harness Policy Management
  ┌──────────────────────────────┐              ┌──────────────────────────┐
  │ 1. GET policy DEBUG          │◄─────────────┤ DEBUG          (project) │
  │ 2. render Dockerfile         │              │  Dockerfile schema       │
  │    (inject BASE_TAG)         │              │  allowed base image      │
  │ 3. conftest -> is the base   │              ├──────────────────────────┤
  │    image the hardened one?   │              │ CD_Docker_Check (account)│
  │ 4. docker build + push       │              │  image schema            │
  └──────────────┬───────────────┘              │  allowed_image = the one │
                 │                              │  the last build produced │
  GitHub Actions — deploy job                   └──────────┬───────────────┘
  ┌──────────────▼───────────────┐    PATCH                │
  │ 5. pin the image just built ─┼─────────────────────────►│
  │ 6. GET it back + conftest    │◄────────────────────────┐│
  │    (round-trip check)        │                         ││
  │ 7. trigger the CD pipeline  ─┼──────────┐              ││
  └──────────────────────────────┘          │              ││
                                            ▼              ││
  Harness — cd_deploy_policy_gate, stage Deploy            ││
  ┌──────────────────────────────────────────────┐         ││
  │ Get_Policy     GET CD_Docker_Check  ─────────┼─────────┘│
  │ Check_Policy   conftest:                      │          │
  │                is <+artifact.image> the       │          │
  │                authorized one?                │          │
  │ record_gate    audit line in the log          │          │
  │ rolling_deploy K8sRollingDeploy  ◄── only if the gate passed
  └──────────────────────────────────────────────┘
```

Two enforcement points, two policies, one idea: **nobody edits the allowed value
by hand.** CI decides which base image is acceptable; the build that passes that
check writes down which application image is acceptable; CD refuses anything
else.

---

## The two policies

| | `DEBUG` | `CD_Docker_Check` |
|---|---|---|
| Scope | project (`devops`) | **account** |
| Enforced in | GitHub Actions build job | CD Deployment stage |
| Input | a Dockerfile, parsed by conftest | `{"image": "<+artifact.image>"}` |
| Rego shape | `input[i].Cmd == "from"` | `input.image` |
| Answers | *was it built from the current hardened base?* | *is this the image CI just approved?* |
| Maintained by | a human / the hardening pipeline | **rewritten by the Action on every build** |

The scope difference is not cosmetic: `CD_Docker_Check` is at account level, so
its API calls carry **only** `accountIdentifier`, while `DEBUG` needs all three
identifiers. Getting this wrong returns a 404 that looks like a permissions
problem.

### Verified locally with `opa` 0.68

`DEBUG` (`policies/debug_ci_dockerfile.rego`):

| Dockerfile | denies |
|---|---|
| `FROM …hardened-nodejs-image:v1.0.42` | 0 — allowed |
| `FROM …hardened-nodejs-image:v1.0.39` | 1 — retired base blocked |
| multi-stage (`node:20-alpine` + hardened base) | 1 — see caveat below |

`CD_Docker_Check` (`policies/cd_docker_check.rego`):

| Input | denies |
|---|---|
| the authorized image | 0 — allowed |
| same repo, different tag | 1 — blocked |
| a different repo entirely | 1 — blocked |
| no `image` field | 1 — **fails closed** |
| `image: ""` | 1 — blocked |

---

## Why the gate lives inside the Deployment stage

This was the decisive design call, and it is worth understanding before the demo
because it is the difference between a real control and a demo prop.

The gate reads **`<+artifact.image>`** — the artifact Harness actually resolved
for this deployment. An earlier, separate stage could not do that: the artifact
is a runtime input *of the Deployment stage*, so a preceding stage can only read
a pipeline variable that the caller supplied. A manual run could then set that
variable to the authorized image while pointing the deployment's artifact at a
different tag — gate green, wrong image deployed.

Inside the stage, there is nothing to lie to. Same policy, same conftest, but
now it is checking the thing that is about to be installed.

---

## API contracts worth writing down

These cost real debugging time. Each one produced a failure that looked like
something else entirely.

| Call | Contract | The trap |
|---|---|---|
| Get policy | `GET /gateway/pm/api/v1/policies/{id}` | The `/gateway` prefix is required and is not in the docs. |
| Update policy | `PATCH /gateway/pm/api/v1/policies/{id}`, **JSON** body `{name, rego}` | It is PATCH, not PUT. Success can be **204**, not just 200. |
| Runtime input template | `POST /pipeline/api/inputSets/template`, JSON | Passing wrong `stageIdentifiers` returns *"stages … don't exist"*. Omitting the field returns the whole pipeline. |
| Execute pipeline | `POST /pipeline/api/pipeline/execute/{id}`, **`Content-Type: application/yaml`**, raw YAML body | Sending JSON `{"runtimeInputYaml": "…"}` returns **200 and starts an execution with every input empty**. |
| Execute specific stages | `POST …/execute/{id}/stages`, **JSON** body | Different contract from the endpoint above. Also requires *Allow selective stage executions* enabled on the pipeline, or it 400s. |

Two of these deserve emphasis:

**The execute endpoint takes raw YAML.** JSON gets a 200 and a run with no
inputs applied — the exact signature of "the pipeline started but the artifact
never resolved". And `curl -d @file` strips newlines, which destroys YAML; it
has to be `--data-binary @file`. Measured: `-d` delivered 0 newlines,
`--data-binary` delivered 25.

**The template does not always contain `<+input>`.** For this pipeline the API
returned empty strings instead, and fields declared `<+input>.default("x")` came
back as the literal string `"x"` *including the quote characters*. Any resolver
that searches for the `<+input>` marker silently fills nothing and reports
success. That is why the Action's resolver fills by variable **name** and by
known **path**, then audits the result for empty / null / quoted values instead
of looking for placeholders.

---

## Files

**Live**

```
policies/debug_ci_dockerfile.rego            CI gate: hardened base image (Harness id: DEBUG)
policies/cd_docker_check.rego                CD gate: image identity (Harness id: CD_Docker_Check)
pipelines/cd_deploy_policy_gate_FINAL.yaml   The CD pipeline as deployed
app-repo/                                    Application repo template (Node.js)
  Dockerfile                                 single stage, ARG BASE_TAG -> FROM ${BASE_TAG}
  package.json, server.js, test/smoke.js     minimal app, no external deps
  .github/workflows/build-and-deploy.yml     build + CI gate + push + pin policy + trigger CD
  k8s/                                       reference manifests
docs/VARIABLES.md                            Every credential, where it comes from, how to test it
docs/GATE-IMAGEN-AUTORIZADA.md               Threat model of the image gate (Spanish)
docs/RUNBOOK-service-step-failed.md          Diagnosing "Failed to complete service step"
scripts/check-credentials.sh                 Tests each credential against the real API
scripts/discover-policy-endpoint.sh          Finds the real path/scope of a policy
```

**Superseded — kept for reference only**

```
policies/hardened_image_cd.rego              First design: OPA schema of my own (crane + Trivy)
policies/cd_docker_check_pipeline.rego       package pipeline variant, for a Policy Set on run
pipelines/cd_deploy_policy_gate.yaml         First design: gate stage + deploy
pipelines/cd_deploy_policy_gate_corregido.yaml
pipelines/cd_deploy_policy_gate_con_verificacion.yaml   Gate as separate stages (weaker, see above)
pipelines/service_TEST_simplificado.yaml     Proposal to reduce the Service's runtime inputs
scripts/prepare-demo-artifacts.sh            Belongs to the first design
scripts/verify-gate-locally.sh               Belongs to the first design
test/cases.sh                                Six scenarios for hardened_image_cd.rego
```

The first design (crane reading OCI labels + Trivy + a custom OPA schema) was
discarded once the real, working CI mechanism was confirmed: download the Rego
over HTTP and run `conftest`. It is kept because its `A1–C1` rule set — base
image traceability, denylist, severity thresholds, change number in Production —
is a good map of what a mature version of this gate would enforce, and several
of those rules answer things asked on the call that the current two policies do
not cover yet.

---

## Caveats and open items

**`allowed_image` is global mutable state, pinned to the last build.** Two
consequences: you cannot redeploy a previously approved image (the policy only
authorizes the newest one, so rollback is blocked), and two concurrent builds
overwrite each other — the second PATCH wins and the first one's deployment is
refused. Neither matters for a demo. If this becomes permanent, the policy
should hold a list: `allowed_images := [...]` with `not input.image in
allowed_images`.

**The Action's round-trip check is circular.** It writes `allowed_image` and
then verifies that same image against that same policy, so it always passes. It
is worth keeping as a smoke test — it proves the PATCH landed, the Rego compiles
and Harness returns it intact — but it is not a control. Note that the negative
case was removed from it; without a "does this policy actually reject a
different image?" assertion, an empty or malformed policy would pass the
positive case and look healthy while blocking nothing.

**The "did the inputs actually arrive?" step was removed.** That check compared
the tag against the created execution and was what caught the silent
JSON-vs-YAML failure. Without it, a future regression of that class shows up as
a deploy failure minutes later instead of immediately.

**`DEBUG` rejects multi-stage Dockerfiles.** The rule walks every `from`
instruction, so a builder stage on `node:20-alpine` is a violation. The current
Dockerfile is single-stage, so this is fine today — but it will bite the moment
someone splits the build. Fixing it means targeting only the final stage.

**Gate failure triggers StageRollback.** `failureStrategies` is `AllErrors ->
StageRollback` for the whole stage, so a blocked deployment attempts to roll back
a stage that never deployed. Harmless, but it muddles the execution history; a
step-level `MarkAsFailure` on `Check_Policy` keeps "blocked by policy" and
"deployment failed" distinguishable.

**The token now needs write access.** `HARNESS_API_KEY` went from reading
policies to modifying them. A 403 on the PATCH means exactly that — read is not
enough.

**`<+artifact.image>` is correct.** Noting this because I twice claimed it was
not, and told you to use `<+artifacts.primary.image>` instead. Both exist:
`<+artifact.image>` is the short form valid in a Deployment stage and is what
Harness's own Kubernetes values.yaml examples use. Nothing needs changing.

---

## How this connects to the other two asks from the call

- **Linear pipeline with GitHub Actions** — this is that pipeline, minus the
  extra environments. The same two-point pattern repeats per promotion: CI
  decides the base image, the build pins the artifact, each environment's deploy
  verifies it. `env_type` is already a pipeline variable, so a Production-only
  rule (a required change number, a stricter severity threshold) is a rule in the
  Rego, not another pipeline.

- **Mass deploy from the driver file** — not started. The shape it wants is the
  orchestrator running this gate once per driver-file entry, so that if 50 of 100
  apps were built on a retired base you get one report of 50 instead of 50
  failures. `disable: true` entries are skipped; `change_number` is already in the
  `Prod` entries.

That is the argument worth making on the call: the gate scales because the
decision lives in one policy document, not replicated across N pipelines. At 100
apps, that is the difference between one change and a hundred.

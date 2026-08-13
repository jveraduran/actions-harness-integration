# Policy Gate en CD — Hardening enforcement antes del despliegue

Respuesta al pedido de Barath y Ramesh en la llamada (min 15:32 – 18:34):

> *"Is there a way we can implement the same policy on the CD part?"*
> *"…if there is a registry of vulnerable images, the application image, not even the base image… if the image is vulnerable, then we should not allow the deployment."*
> *"Both combination will be best. One is the application container image itself… another approach will be based on the base image level."*

Las dos validaciones, en un solo gate, alimentadas por la **misma policy** que ya
aplicas en CI.

---

## La idea central del demo

El punto fuerte no es que Harness pueda bloquear un despliegue. Es que hay **una
sola fuente de verdad** y **dos puntos de aplicación**:

```
        ┌─────────────────────────────────────────┐
        │   Pipeline de hardening de base image   │
        │   (el que ya demostraste)               │
        │   0 críticos  ->  PATCH de la policy    │
        └────────────────┬────────────────────────┘
                         │  escribe stable_base
                         ▼
        ┌─────────────────────────────────────────┐
        │   Policy en Harness Policy Management   │
        │   stable_base = 1.0.42                  │
        │   blocked_artifacts = [...]             │
        └───────┬─────────────────────┬───────────┘
                │                     │
        lee     │                     │  lee
                ▼                     ▼
    ┌───────────────────┐   ┌─────────────────────┐
    │  Gate en CI       │   │  Gate en CD         │
    │  (Dockerfile)     │   │  (artefacto + base) │
    │  ya demostrado    │   │  ESTO ES LO NUEVO   │
    └───────────────────┘   └─────────────────────┘
```

Nadie edita la versión estable a mano. Cuando el pipeline de hardening publica
`1.0.42`, el gate de CD empieza a rechazar todo lo construido sobre `1.0.39`
**en el mismo instante**, sin tocar un solo pipeline.

---

## Qué valida el gate

| Regla | Qué comprueba | Origen en la llamada |
|---|---|---|
| **A1** | El artefacto declara su base image (label OCI o SBOM). Si no, **falla cerrado** | trazabilidad, min 18:14 |
| **A2** | La base image viene del repo hardened aprobado | Ramesh, min 17:37 |
| **A3** | La versión de base image es la vigente (`stable_base.tag`) | el caso que ya demostraste en CI |
| **A4** | El digest coincide, no solo el tag (detecta tags sobrescritos) | *añadido — no lo pidieron* |
| **B1** | El artefacto de aplicación no está en la denylist | Barath, min 16:50 |
| **B2/B3** | El escaneo del artefacto no supera los umbrales de críticos/altas | Barath, min 17:00 |
| **C1** | Producción exige `change_number` | campo que ya trae el driver file |

`A4` y `C1` no los pidieron: son valor añadido que puedes ofrecer en la llamada.
`C1` en particular conecta este gate con el driver file del mass deploy, que ya
trae `change_number` en las entradas de `Prod`.

---

## Cómo funciona el pipeline

`pipelines/cd_deploy_policy_gate.yaml` — dos stages:

**Stage 1 · Pre-Deploy Gate** (recolecta hechos, luego decide una sola vez)

1. `prepare_tools` — descarga `crane` y `opa` al workspace compartido `/harness`
2. `fetch_policy` — `GET` a Harness Policy Management, extrae el Rego → misma llamada que ya usas en CI
3. `resolve_base_image` — `crane config` sobre el artefacto, lee `org.opencontainers.image.base.name` / `.base.digest`
4. `scan_app_image` — Trivy sobre el artefacto de aplicación, `--exit-code 0` a propósito (el veredicto lo da la policy, no el scanner)
5. `evaluate_gate` — arma un único `input.json` y evalúa `deny` con OPA. Si hay violaciones, imprime cada mensaje y sale con 1

**Stage 2 · Deploy** — solo corre si el gate pasó, y arranca registrando el veredicto en el log del despliegue (auditoría).

La separación importa: **recolectar hechos ≠ decidir**. Los cuatro primeros pasos
solo producen datos; toda la lógica de decisión vive en el Rego, que es lo que el
cliente puede versionar y auditar.

---

## El prerequisito que hay que negociar con el cliente

**El gate no funciona si el artefacto no declara su base image.** Ahí está el
único trabajo que cae del lado de ellos, y conviene plantearlo el viernes con las
tres opciones sobre la mesa:

| Opción | Qué implica | Cuándo elegirla |
|---|---|---|
| **Labels OCI** (recomendada) | Añadir `labels:` en `docker/build-push-action`. Ver `ci/github-actions-build-and-trigger.yml`. Cambio de ~4 líneas por repo | si pueden tocar el workflow de GHA |
| **SBOM / SSCA** | Harness SSCA genera y firma el SBOM en el build; el gate lo consulta en vez de leer labels | si ya piensan adoptar SSCA — es la más robusta, pero suma alcance |
| **Properties de JFrog** | Un job estampa la base image como property del artefacto en Artifactory | si no pueden tocar el build en absoluto |

La opción de labels es la que menos fricción tiene, y como bonus el workflow de
ejemplo **resuelve la base image desde la misma policy en tiempo de build**, así
que el `Dockerfile` deja de tener la versión hardcodeada. Eso mata de raíz el
problema que demostraste en CI: ya no hay que bloquear al desarrollador por poner
`1.0.39`, porque el desarrollador nunca escribe la versión.

Mencióna eso en la llamada. Es el argumento más fuerte que tienes.

---

## Guion sugerido (unos 8 minutos)

1. **Contexto** (30 s) — "Me pidieron llevar la policy a CD. Lo hice, y validando las dos cosas: la app image y la base image con la que se construyó."
2. **Mostrar la policy** (1 min) — señalar `stable_base` y recordar que ese bloque lo escribe el pipeline de hardening, no una persona.
3. **Caso que pasa** (1.5 min) — desplegar `app1:v1.2`, construido sobre `1.0.42`. El log del gate muestra la base image resuelta y el veredicto. El deploy procede.
4. **Caso bloqueado por base image** (2 min) — desplegar un artefacto construido sobre `1.0.39`. El gate falla con `[A3]` y el mensaje dice exactamente qué reconstruir. **Nada llegó al cluster.** Este es el momento del demo.
5. **Caso bloqueado por denylist** (1.5 min) — `app2:v1.5` con base image correcta pero en `blocked_artifacts`. Muestra que las dos validaciones son independientes: la app image puede ser vulnerable aunque la base sea perfecta. Es literalmente lo que dijo Barath.
6. **Cierre** (1 min) — sin tocar ningún pipeline, el equipo de seguridad publica una base image nueva o añade un artefacto a la denylist, y los N pipelines de despliegue lo respetan de inmediato. Con 100 apps eso es la diferencia entre un cambio y cien.

Prepara los tres artefactos **antes** de la llamada. En la reunión pasada perdiste
tiempo esperando que el push se reflejara (min 11:38) y tuviste que saltarte
parte del flujo. Con imágenes ya publicadas el gate corre en menos de un minuto.

---

## Validar la policy localmente

```bash
curl -sSL -o opa https://openpolicyagent.org/downloads/v0.68.0/opa_linux_amd64_static
chmod +x opa
OPA=./opa ./test/cases.sh
```

Seis escenarios, ya ejecutados y verificados:

| Caso | Esperado | Resultado |
|---|---|---|
| Artefacto conforme | permitido | ✅ permitido |
| Base image `1.0.39` | bloqueado `[A3]` | ✅ bloqueado |
| Artefacto en denylist | bloqueado `[B1]` | ✅ bloqueado |
| Sin label de base image | bloqueado `[A1]` | ✅ bloqueado |
| Prod sin change_number + 2 críticos | bloqueado `[B2] [B3] [C1]` | ✅ 3 violaciones |
| Repo exento (sandbox) | permitido | ✅ permitido |

---

## Cosas que tienes que ajustar o verificar antes del viernes

**Ajustes obvios de entorno**

- `orgIdentifier` / `projectIdentifier` en el pipeline
- Secretos: `harness_api_key`, `artifact_registry_user`, `artifact_registry_token`
- Repos y tags de ejemplo (`harness-registry.example.io/...`) por los tuyos
- `serviceRef` / `environmentRef` / `infrastructureDefinitions` del stage de Deploy

**Verificaciones que no pude hacer desde aquí**

1. **El endpoint de Policy Management.** Usé `GET /pl/api/v1/policy/{id}` y extraigo el campo `.rego`. Tú ya llamas a este endpoint en el gate de CI — sustituye por la ruta y el campo exactos que te funcionan, y ajusta el `jq`.
2. **Stage tipo CI en una cuenta CD-only.** Usé un stage `CI` con `cloneCodebase: false` sobre Harness Cloud porque los steps `Run` son cómodos y el workspace `/harness` se comparte entre pasos. Si la cuenta del demo no tiene licencia de CI, cámbialo por un stage `Custom` con `Container` steps, o mueve los cinco pasos a un **step group dentro del stage de Deployment**. Esa última variante tiene una ventaja: ahí sí resuelve `<+artifact.image>` y `<+artifact.tag>`, así que no necesitas las variables de pipeline. La usé como variables porque **coincide con el flujo real del cliente** — GHA llama a la API pasando el tag, y el driver file inyecta los valores por input set.
3. **Sintaxis Rego del engine de Harness.** Escribí `deny[msg] { }` (Rego v0), que es lo que usan los ejemplos de Harness y lo que valida OPA 0.68. Si el engine de tu cuenta ya corre OPA 1.x, habrá que pasar a `deny contains msg if { }`.
4. **El conteo de severidades de Trivy** lo hago con `grep -c` sobre el JSON. Funciona y es a prueba de cambios de schema, pero si prefieres precisión usa `jq '[.Results[].Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length'`.
5. **Autenticación de `crane`** con el registry: si usan JFrog con tokens de acceso, verifica que `crane auth login` funcione con esas credenciales antes del demo.

---

## Cómo esto se conecta con los otros dos temas

Este gate no es una pieza aislada — es el bloque que se reutiliza en los otros dos
pedidos de la llamada:

- **Pipeline lineal con GHA** → el gate es el primer stage antes de cada
  promoción de entorno. Dev, QA, UAT y Prod pasan por el mismo gate con distinto
  `env_type`. Y `C1` hace que solo Prod exija el change number.
- **Mass deploy con el driver file** → el orquestador ejecuta el gate **una vez
  por entrada** del driver file. Con `disable: true` la entrada ni se evalúa;
  con `change_number` presente en `Prod`, `C1` se satisface automáticamente. Si
  50 de 100 apps se construyeron sobre una base retirada, el orquestador te da un
  reporte de las 50 en una sola ejecución en lugar de fallar de a una.

Ese es el argumento de venta: el gate escala solo porque la decisión está
centralizada en un documento, no replicada en N pipelines.

---

## Archivos

```
policies/hardened_image_cd.rego              La policy (fuente de verdad)
pipelines/cd_deploy_policy_gate.yaml         Pipeline de Harness: gate + deploy
ci/github-actions-build-and-trigger.yml      Prerequisito: labels OCI + trigger a Harness
test/cases.sh                                Seis escenarios validados con OPA
```

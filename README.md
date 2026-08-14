# app-repo — repositorio de aplicación del demo

Lo que faltaba: sin esto el workflow de GitHub Actions no llega al `docker
build`. Es un repo completo y ejecutable, no un fragmento.

```
pom.xml                              Build Maven (sin dependencias de runtime)
src/main/java/.../Application.java   App mínima: /health y /version
src/test/java/.../ApplicationTest.java   2 tests JUnit 5
Dockerfile                           Multi-stage, base por build-arg
.dockerignore
.github/workflows/build-and-deploy.yml   Build + push + disparo del CD
k8s/                                 Manifiestos para el stage de Deployment
gradle-variant/                      Misma app con Gradle (copiar a la raíz)
```

## La línea que importa

```dockerfile
ARG BASE_IMAGE          # antes del primer FROM, para poder usarse en un FROM

FROM maven:3.9-eclipse-temurin-17 AS build
...
FROM ${BASE_IMAGE} AS runtime      # <-- la base la decide la policy, no el repo
ARG BASE_IMAGE                     # redeclarar para usarlo en el cuerpo
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
```

No hay ninguna versión de base image escrita en el repo. El workflow la lee de
la policy de Harness y la inyecta. Consecuencia práctica para la llamada del
viernes: **el caso que demostraste en CI deja de poder ocurrir**, porque el
desarrollador ya no escribe la versión en ningún sitio. El gate de CD pasa de
ser un castigo a ser una red de seguridad.

El multi-stage no interfiere con el gate: el label refleja la base del último
stage, y la imagen de build (`maven:3.9`) no aparece en la validación — es
correcto que no aparezca, porque no se despliega.

## Cómo generar el artefacto que el gate debe bloquear

Por el camino normal (`push`) todos los artefactos salen conformes, así que no
habría nada que bloquear en el demo. Para eso está el `workflow_dispatch`:

```
Actions -> build-and-deploy -> Run workflow
  base_image_override: harness-registry.example.io/platform/base-java:1.0.39
```

Sale con el tag sufijado `-stalebase` para no confundirlo, y el workflow emite
un `::warning::` avisando que ese artefacto debe ser rechazado.

Más rápido aún, sin pasar por GHA: `../scripts/prepare-demo-artifacts.sh`
construye y publica los tres artefactos del demo de una sola vez.

## Verificado en este contenedor

```
mvn clean package        BUILD SUCCESS, target/app.jar (4.8 KB)
mvn test                 Tests run: 2, Failures: 0, Errors: 0
java -jar target/app.jar GET /health  -> ok
                         GET /version -> {"app":"app1","version":"1.0.0",
                                          "base_image":"reg/base-java:1.0.42", ...}
```

El `docker build` **no** pudo ejecutarse aquí: este sandbox no tiene daemon de
Docker. La estructura del Dockerfile sí está validada estáticamente (orden de
`ARG` respecto a `FROM` y `LABEL`, y que el `COPY --from` apunte al jar que
Maven y Gradle producen). Corre el script de preparación una vez en tu máquina
antes de la llamada.

## Ajustes antes de usarlo

- `REGISTRY` y `APP_REPO` en el workflow (`harness-registry.example.io/...`)
- Secretos del repo: `HARNESS_API_KEY`, `HARNESS_ACCOUNT_ID`, `HARNESS_ORG_ID`,
  `HARNESS_PROJECT_ID`, `REGISTRY_USER`, `REGISTRY_TOKEN`
- `USER 10001` en el Dockerfile: si tu base hardened ya define un usuario no
  root, usa su UID
- El endpoint de Policy Management, igual que en el pipeline del gate

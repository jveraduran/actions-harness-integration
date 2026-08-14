# ===========================================================================
#  app1 - Dockerfile del demo de policy gate
#
#  LA LÍNEA IMPORTANTE ES `FROM ${BASE_IMAGE}` EN EL STAGE DE RUNTIME.
#
#  Fíjate en lo que NO hay aquí: ninguna versión de base image escrita a mano.
#  La base la resuelve el workflow desde la policy de Harness y la inyecta por
#  build-arg. Ese es el cambio que hace que el problema que demostraste en CI
#  (un desarrollador poniendo 1.0.39 en el Dockerfile) deje de existir: el
#  desarrollador ya no escribe la versión en ningún sitio.
#
#  El ARG va ANTES del primer FROM para poder usarse en las líneas FROM.
# ===========================================================================
ARG BASE_IMAGE

# ---------------------------------------------------------------------------
#  Stage 1 - build. Irrelevante para el gate: esta imagen no se publica.
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /src

# Capa de dependencias separada del código: los rebuilds del demo son rápidos.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q clean package

# ---------------------------------------------------------------------------
#  Stage 2 - runtime. ESTA es la base que valida el gate de CD.
#
#  El gate lee el label org.opencontainers.image.base.name del artefacto
#  publicado, que refleja la base del ÚLTIMO stage. Por eso el multi-stage no
#  interfiere: la imagen de build (maven:3.9) no aparece en la validación,
#  y es correcto que no aparezca — no se despliega.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# Redeclarar para poder usarlos dentro del stage. Los ARG globales son
# visibles en las líneas FROM, pero no en el cuerpo de un stage.
ARG BASE_IMAGE
ARG BASE_DIGEST=""
ARG APP_VERSION="dev"
ARG GIT_SHA=""

# ---------------------------------------------------------------------------
#  Los labels que consume el gate.
#
#  Se declaran también aquí, no solo en el workflow, para que un `docker build`
#  local produzca un artefacto igual de válido. Si solo estuvieran en el
#  workflow, cualquier build fuera de GHA generaría una imagen sin trazabilidad
#  que el gate rechazaría por la regla [A1].
# ---------------------------------------------------------------------------
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.title="app1"

# Se exponen como entorno para que /version las devuelva en caliente:
# permite comprobar la base image de un pod ya corriendo, sin tocar el registry.
ENV BASE_IMAGE_NAME="${BASE_IMAGE}" \
    BASE_IMAGE_DIGEST="${BASE_DIGEST}"

WORKDIR /app
COPY --from=build /src/target/app.jar /app/app.jar

# Usuario no root. Si tu base image hardened ya define uno, sustituye por su UID.
USER 10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/bin/sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && head -1 <&3 | grep -q 200"]

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]

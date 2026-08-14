# ===========================================================================
#  hardening-reader-1-nodejs — Dockerfile (Node.js)
#
#  Reemplaza al Dockerfile de Java que estaba aquí antes. Ese venía de las
#  primeras vueltas de este trabajo, de cuando aún no habíamos confirmado que
#  tu app real es Node — lo confirmaste con tu pipeline de Harness y tu
#  Dockerfile real. Esta versión ya está alineada con lo que el workflow de
#  GitHub Actions realmente hace:
#
#    - usa ARG BASE_TAG (no ARG BASE_IMAGE) — coincide con lo que el paso
#      "Renderizar Dockerfile con BASE_TAG" sustituye vía sed, y con lo que
#      el paso "Build y push" pasa como --build-arg
#    - el FROM usa ${BASE_TAG} en vez de una versión fija (a diferencia del
#      Dockerfile que pegaste antes, con ':v1.0.41' tecleado a mano) — así el
#      tag que dispara el workflow sí decide qué base se usa, tanto para el
#      chequeo de conftest como para el build real
#    - un solo stage, igual que tu Dockerfile real (sin el multi-stage de
#      build que sí tenía sentido para Java con Maven, pero no aplica aquí)
# ===========================================================================

ARG BASE_TAG

FROM pkg.harness.io/ucbjyokwry69wqkdogpexg/harness-demo/hardened-nodejs-image:${BASE_TAG}

# Redeclarar para poder usar el valor dentro del cuerpo de este stage
# (los ARG globales solo son visibles en las líneas FROM).
ARG BASE_TAG

# Se expone como variable de entorno para que /version pueda devolverla en
# caliente — útil para confirmar en un pod ya desplegado qué base trae.
ENV BASE_TAG=${BASE_TAG}

WORKDIR /usr/src/app

# Copiar solo los manifiestos primero: capa de dependencias cacheable,
# no se reinstala nada si solo cambia el código de la app.
COPY package*.json ./

# La base usa una versión de Node antigua (ver el comentario original:
# "uses a very old version of Node (v10)") — por eso este scaffold no trae
# dependencias externas, solo el módulo http nativo, para minimizar el
# riesgo de incompatibilidad.
RUN npm install --only=production

COPY . .

EXPOSE 3000

# Si tu base image hardened ya define un usuario no root, considera
# descomentar esto con su UID real (no lo fuerzo aquí porque no lo confirmé):
# USER 10001

CMD ["node", "server.js"]

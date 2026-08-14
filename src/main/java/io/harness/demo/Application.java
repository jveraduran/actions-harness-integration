package io.harness.demo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

/**
 * Aplicación mínima para el demo del policy gate.
 *
 * No usa framework: solo el servidor HTTP del JDK. El objetivo del repo es
 * producir un artefacto de contenedor real con los labels OCI correctos, no
 * demostrar nada del stack de aplicación.
 *
 * Endpoints:
 *   GET /health   -> 200 "ok"
 *   GET /version  -> versión del artefacto y base image con la que se construyó
 */
public final class Application {

    private static final int PORT = Integer.parseInt(
            System.getenv().getOrDefault("PORT", "8080"));

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);
        server.createContext("/health", exchange -> respond(exchange, 200, "ok"));
        server.createContext("/version", exchange -> respond(exchange, 200, versionPayload()));
        server.setExecutor(Executors.newFixedThreadPool(4));

        Runtime.getRuntime().addShutdownHook(new Thread(() -> server.stop(0)));

        System.out.println("app1 escuchando en el puerto " + PORT);
        System.out.println(versionPayload());
        server.start();
    }

    /**
     * Devuelve la versión del artefacto y, si el build las inyectó como
     * variables de entorno, la base image usada. Sirve para comprobar en
     * caliente qué base trae un pod ya desplegado.
     */
    static String versionPayload() {
        String appVersion = valueOr(
                Application.class.getPackage().getImplementationVersion(), "dev");
        String baseName = valueOr(System.getenv("BASE_IMAGE_NAME"), "desconocida");
        String baseDigest = valueOr(System.getenv("BASE_IMAGE_DIGEST"), "desconocido");

        return String.format(
                "{\"app\":\"app1\",\"version\":\"%s\",\"base_image\":\"%s\",\"base_digest\":\"%s\"}",
                appVersion, baseName, baseDigest);
    }

    static String valueOr(String value, String fallback) {
        return (value == null || value.isBlank()) ? fallback : value;
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}

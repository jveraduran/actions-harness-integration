package io.harness.demo;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests mínimos, pero reales: el stage de test del pipeline necesita algo que
 * ejecutar para que Test Intelligence tenga resultados que mostrar.
 */
class ApplicationTest {

    @Test
    @DisplayName("valueOr cae al valor por defecto cuando la entrada está vacía")
    void valueOrFallsBack() {
        assertEquals("fallback", Application.valueOr(null, "fallback"));
        assertEquals("fallback", Application.valueOr("", "fallback"));
        assertEquals("fallback", Application.valueOr("   ", "fallback"));
        assertEquals("real", Application.valueOr("real", "fallback"));
    }

    @Test
    @DisplayName("El payload de /version es JSON con los campos de trazabilidad")
    void versionPayloadIsWellFormed() {
        String payload = Application.versionPayload();

        assertTrue(payload.startsWith("{") && payload.endsWith("}"),
                "debe ser un objeto JSON: " + payload);
        assertTrue(payload.contains("\"app\":\"app1\""), payload);
        assertTrue(payload.contains("\"base_image\""),
                "el payload debe exponer la base image para trazabilidad: " + payload);
        assertTrue(payload.contains("\"base_digest\""), payload);
    }
}

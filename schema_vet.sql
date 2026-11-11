-- =====================================================================
-- Bot WhatsApp Veterinaria · Schema de datos del bot
-- Postgres 14+. Separado de las tablas internas de n8n (schema "vet").
-- Ejecutar una sola vez sobre la base n8n-db (o en Supabase).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS vet;
SET search_path TO vet;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
CREATE TYPE especie_t       AS ENUM ('perro', 'gato', 'ave', 'conejo', 'roedor', 'reptil', 'otro');
CREATE TYPE tipo_atencion_t AS ENUM ('vacuna', 'control', 'consulta', 'desparasitacion', 'cirugia', 'otro');
CREATE TYPE estado_cita_t   AS ENUM ('agendada', 'confirmada', 'cancelada', 'atendida', 'no_asistio');
CREATE TYPE modo_conv_t     AS ENUM ('bot', 'humano');
CREATE TYPE tipo_record_t   AS ENUM ('vacuna', 'control', 'cita_manana');
CREATE TYPE estado_envio_t  AS ENUM ('pendiente', 'enviado', 'fallido');

-- ---------------------------------------------------------------------
-- updated_at automático
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Dueños: se identifican por su número de WhatsApp (formato E.164 sin +, ej. 56912345678)
-- ---------------------------------------------------------------------
CREATE TABLE duenos (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  telefono_whatsapp  text NOT NULL UNIQUE CHECK (telefono_whatsapp ~ '^[0-9]{8,15}$'),
  nombre             text,
  email              text,
  acepta_recordatorios boolean NOT NULL DEFAULT true,   -- opt-out si el cliente pide no recibir avisos
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_duenos_updated BEFORE UPDATE ON duenos
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Mascotas
-- ---------------------------------------------------------------------
CREATE TABLE mascotas (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dueno_id         bigint NOT NULL REFERENCES duenos(id) ON DELETE CASCADE,
  nombre           text NOT NULL,
  especie          especie_t NOT NULL DEFAULT 'otro',
  raza             text,
  fecha_nacimiento date,
  activa           boolean NOT NULL DEFAULT true,       -- false si falleció o dejó de atenderse
  notas            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dueno_id, nombre)
);
CREATE INDEX idx_mascotas_dueno ON mascotas(dueno_id);
CREATE TRIGGER trg_mascotas_updated BEFORE UPDATE ON mascotas
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Atenciones: historial. proxima_fecha es lo que gatilla los recordatorios.
-- ---------------------------------------------------------------------
CREATE TABLE atenciones (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  mascota_id     bigint NOT NULL REFERENCES mascotas(id) ON DELETE CASCADE,
  fecha          date NOT NULL DEFAULT current_date,
  tipo           tipo_atencion_t NOT NULL,
  detalle        text,                                   -- ej. "Óctuple", "Antirrábica"
  proxima_fecha  date,                                   -- próxima dosis o control
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_atenciones_mascota ON atenciones(mascota_id, fecha DESC);
CREATE INDEX idx_atenciones_proxima ON atenciones(proxima_fecha) WHERE proxima_fecha IS NOT NULL;

-- ---------------------------------------------------------------------
-- Citas: espejo de los eventos de Google Calendar
-- ---------------------------------------------------------------------
CREATE TABLE citas (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  mascota_id       bigint NOT NULL REFERENCES mascotas(id) ON DELETE CASCADE,
  fecha_hora       timestamptz NOT NULL,
  duracion_min     integer NOT NULL DEFAULT 30 CHECK (duracion_min > 0),
  motivo           text,
  estado           estado_cita_t NOT NULL DEFAULT 'agendada',
  google_event_id  text UNIQUE,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_citas_fecha  ON citas(fecha_hora) WHERE estado IN ('agendada', 'confirmada');
CREATE INDEX idx_citas_mascota ON citas(mascota_id);
CREATE TRIGGER trg_citas_updated BEFORE UPDATE ON citas
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Conversaciones: modo bot/humano y memoria corta para la IA
-- ---------------------------------------------------------------------
CREATE TABLE conversaciones (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dueno_id            bigint NOT NULL UNIQUE REFERENCES duenos(id) ON DELETE CASCADE,
  modo                modo_conv_t NOT NULL DEFAULT 'bot',
  ultima_interaccion  timestamptz NOT NULL DEFAULT now(),  -- define la ventana de 24 h de Meta
  contexto            jsonb NOT NULL DEFAULT '[]'::jsonb,  -- últimos mensajes para la IA
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_conv_updated BEFORE UPDATE ON conversaciones
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Recordatorios enviados: evita duplicados y deja trazabilidad
-- ---------------------------------------------------------------------
CREATE TABLE recordatorios (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tipo           tipo_record_t NOT NULL,
  atencion_id    bigint REFERENCES atenciones(id) ON DELETE CASCADE,
  cita_id        bigint REFERENCES citas(id) ON DELETE CASCADE,
  dueno_id       bigint NOT NULL REFERENCES duenos(id) ON DELETE CASCADE,
  estado         estado_envio_t NOT NULL DEFAULT 'pendiente',
  wa_message_id  text,                                    -- id que devuelve Meta
  error          text,
  enviado_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(atencion_id, cita_id) = 1)
);
CREATE UNIQUE INDEX uq_record_atencion ON recordatorios(atencion_id) WHERE atencion_id IS NOT NULL;
CREATE UNIQUE INDEX uq_record_cita     ON recordatorios(cita_id)     WHERE cita_id IS NOT NULL;

-- =====================================================================
-- Vistas que consume n8n
-- =====================================================================

-- Vacunas y controles que vencen en los próximos 7 días y aún no se avisaron
CREATE OR REPLACE VIEW v_recordatorios_pendientes AS
SELECT a.id            AS atencion_id,
       a.tipo,
       a.detalle,
       a.proxima_fecha,
       m.id            AS mascota_id,
       m.nombre        AS mascota,
       d.id            AS dueno_id,
       d.nombre        AS dueno,
       d.telefono_whatsapp
FROM atenciones a
JOIN mascotas m ON m.id = a.mascota_id AND m.activa
JOIN duenos   d ON d.id = m.dueno_id  AND d.acepta_recordatorios
WHERE a.tipo IN ('vacuna', 'control')
  AND a.proxima_fecha BETWEEN current_date AND current_date + 7
  AND NOT EXISTS (SELECT 1 FROM recordatorios r WHERE r.atencion_id = a.id)
  -- si ya existe una atención posterior del mismo tipo, el recordatorio ya no aplica
  AND NOT EXISTS (
        SELECT 1 FROM atenciones a2
        WHERE a2.mascota_id = a.mascota_id
          AND a2.tipo = a.tipo
          AND a2.fecha > a.fecha);

-- Citas de mañana (hora de Santiago) pendientes de confirmación
CREATE OR REPLACE VIEW v_citas_manana AS
SELECT c.id            AS cita_id,
       c.fecha_hora AT TIME ZONE 'America/Santiago' AS fecha_hora_local,
       c.motivo,
       m.nombre        AS mascota,
       d.id            AS dueno_id,
       d.nombre        AS dueno,
       d.telefono_whatsapp
FROM citas c
JOIN mascotas m ON m.id = c.mascota_id
JOIN duenos   d ON d.id = m.dueno_id
WHERE c.estado IN ('agendada', 'confirmada')
  AND (c.fecha_hora AT TIME ZONE 'America/Santiago')::date
      = (now() AT TIME ZONE 'America/Santiago')::date + 1
  AND NOT EXISTS (SELECT 1 FROM recordatorios r WHERE r.cita_id = c.id);

-- Ficha rápida del cliente para dar contexto a la IA
CREATE OR REPLACE VIEW v_ficha_cliente AS
SELECT d.telefono_whatsapp,
       d.id   AS dueno_id,
       d.nombre AS dueno,
       COALESCE(jsonb_agg(jsonb_build_object(
         'mascota_id', m.id,
         'nombre', m.nombre,
         'especie', m.especie,
         'raza', m.raza,
         'proximas', (SELECT jsonb_agg(jsonb_build_object('tipo', a.tipo, 'detalle', a.detalle, 'fecha', a.proxima_fecha))
                      FROM atenciones a
                      WHERE a.mascota_id = m.id AND a.proxima_fecha >= current_date)
       )) FILTER (WHERE m.id IS NOT NULL), '[]'::jsonb) AS mascotas
FROM duenos d
LEFT JOIN mascotas m ON m.dueno_id = d.id AND m.activa
GROUP BY d.id;

-- =====================================================================
-- Usuario de solo lo necesario para n8n (opcional, recomendado)
-- Reemplaza la contraseña antes de ejecutar.
-- =====================================================================
-- CREATE ROLE bot_vet LOGIN PASSWORD 'cambiar_esta_clave';
-- GRANT USAGE ON SCHEMA vet TO bot_vet;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA vet TO bot_vet;
-- GRANT USAGE ON ALL SEQUENCES IN SCHEMA vet TO bot_vet;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA vet GRANT SELECT, INSERT, UPDATE ON TABLES TO bot_vet;

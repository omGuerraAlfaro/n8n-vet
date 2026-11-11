# n8n en Render – Bot WhatsApp Veterinaria

Despliegue de n8n con Postgres en Render usando un Blueprint (`render.yaml`).

## Pasos

1. **Repo:** crea un repo en GitHub (puede ser privado) y sube `render.yaml` a la raíz.
2. **Blueprint:** en Render ve a *New → Blueprint*, conecta el repo y confirma. Render crea:
   - `n8n-veterinaria` (servicio web, plan Starter)
   - `n8n-db` (Postgres)
3. **Variables pendientes:** Render te pedirá `WEBHOOK_URL` y `N8N_EDITOR_BASE_URL`. Si aún no conoces la URL, déjalas vacías, espera el primer deploy y luego ponles la URL del servicio, por ejemplo:
   ```
   https://n8n-veterinaria.onrender.com/
   ```
   Guarda y Render redepliega solo.
4. **Cuenta owner:** abre la URL, crea el usuario administrador de n8n. Ese primer usuario es el dueño de la instancia, así que hazlo apenas termine el deploy.
5. **Verifica:** `https://<tu-url>/healthz` debe responder `{"status":"ok"}`.

## Notas

- **N8N_ENCRYPTION_KEY** la genera Render. Respáldala en un lugar seguro: si se pierde, todas las credenciales guardadas en n8n (Meta, Google, IA) quedan inutilizables.
- **Versión:** fija la imagen a una versión concreta (ej. `n8nio/n8n:1.x.x`) antes de entregar al cliente, para que un update no rompa los flujos sin aviso.
- **Datos del bot:** las tablas de dueños, mascotas y citas pueden ir en este mismo Postgres, en un schema aparte (`vet`), o en Supabase. Lo vemos en el paso 3.
- **Dominio propio (opcional):** en *Settings → Custom Domains* del servicio puedes usar algo como `bot.veterinaria.cl`; si lo haces, actualiza `WEBHOOK_URL` y `N8N_EDITOR_BASE_URL`.

## Siguiente paso

Crear la app en Meta for Developers, activar WhatsApp con el número de prueba y apuntar su webhook a n8n.

# Vai Rodar - Deploy y carpetas oficiales

El repo se publica como un solo sitio Netlify con rutas limpias.

## Configuracion Netlify

- Build command: `npm run build`
- Publish directory: `dist`
- Functions directory: `netlify/functions`

`dist/` se genera automaticamente con `scripts/build-dist.js` y no es fuente oficial.

## Rutas publicas

| Ruta | Fuente | Uso |
| --- | --- | --- |
| `/` | `apps/user-app/` | App principal usuario, PWA, chat IA, solicitudes, piezas, compra/venta autos |
| `/oficinas` | `apps/workshop-entry/` | Entrada para negocios: cadastro o backoffice |
| `/oficinas/cadastro` | `apps/workshop-register-supabase/` | Registro Supabase de oficinas/comercios de piezas |
| `/oficinas/painel` | `apps/workshop-app/` | Backoffice de oficinas/comercios |
| `/admin` | `apps/admin-backoffice/` | Backoffice interno Vai Rodar |

## Backend y funciones

- `netlify/functions/ai-diagnose.js`: chatbot IA con OpenAI.
- `netlify/functions/consultar-fipe.js`: consulta FIPE/placa via APIBrasil.
- `netlify/functions/consulta-placa.js`: compatibilidad GET para placa, delega en FIPE.
- `netlify/functions/admin-data.js`: lectura admin con service role.
- `netlify/functions/admin-action.js`: acciones admin con service role.
- `netlify/functions/notify-event.js`: push de mensajes, propuestas y ciclo de reservas.
- `netlify/functions/whatsapp-send.js`: envio de mensajes del CRM WhatsApp Cloud.
- `netlify/functions/whatsapp-webhook.js`: verificacion y recepcion del webhook de Meta.
- `supabase/migrations/`: SQL ejecutado o pendiente de ejecutar en Supabase.

## Migraciones del paquete 20/07/2026

- `20260720_flujo_propuesta_reserva.sql`: modalidades, validez, aceptacion,
  agenda, confirmacion, cancelacion y cierre de reservas.
- `20260720_crm_whatsapp_y_onboarding.sql`: CRM WhatsApp y estado del
  onboarding del backoffice de oficina.

Netlify no ejecuta migraciones SQL. Deben aplicarse en Supabase antes de
probar las funciones que dependen de ellas.

## Variables Netlify necesarias

- `ADMIN_PASSWORD`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `OPENAI_API_KEY_VR`
- `APIBRASIL_BEARER_TOKEN`
- `APIBRASIL_HOMOLOG`
- `VAPID_PUBLIC_KEY`
- `VAPID_PRIVATE_KEY`
- `WHATSAPP_TOKEN`
- `WHATSAPP_PHONE_NUMBER_ID`
- `WHATSAPP_VERIFY_TOKEN`

Opcional:

- `OPENAI_MODEL`
- `WHATSAPP_GRAPH_VERSION` (default `v20.0`)

Los valores secretos solo se configuran en Netlify. Nunca se escriben en
HTML, documentos, commits ni funciones.

## Carpetas no productivas

- `prototypes/`: pruebas visuales e historico.
- `exports/`: zips, capturas y exports antiguos.
- `archive/`: material legado.
- `integrations/`: integraciones legadas/temporales.

Estas carpetas no entran al build de Netlify.

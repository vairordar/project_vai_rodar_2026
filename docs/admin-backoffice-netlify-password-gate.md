# Admin Backoffice - Acceso por contraseña unica

El admin backoffice ya no depende de Supabase Auth para entrar.

Flujo:

1. `apps/admin-backoffice/index.html` pide solo una contraseña.
2. El frontend llama a Netlify Functions:
   - `/.netlify/functions/admin-data`
   - `/.netlify/functions/admin-action`
3. Las functions validan `ADMIN_PASSWORD`.
4. Si la contraseña es correcta, consultan/modifican Supabase usando `SUPABASE_SERVICE_ROLE_KEY`.

## Variables obligatorias en Netlify

Configurar en Netlify > Site settings > Environment variables:

```text
ADMIN_PASSWORD
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
```

No poner `SUPABASE_SERVICE_ROLE_KEY` en ningun HTML o JS del frontend.

## Archivos creados

```text
netlify/functions/admin-common.js
netlify/functions/admin-data.js
netlify/functions/admin-action.js
```

## Acciones soportadas

`admin-action` acepta:

```json
{ "action": "setWorkshopVisibility", "payload": { "workshop_id": "...", "approval_status": "approved", "visible": true, "open": true } }
```

```json
{ "action": "createSubscriptionPayment", "payload": { "workshop_id": "...", "amount": 1190, "method": "Manual", "reference": "ADMIN-001", "duration_days": 365 } }
```

## Nota local

Si se abre el admin con `file://`, entra en modo demo porque las Netlify Functions solo existen en Netlify o usando `netlify dev`.


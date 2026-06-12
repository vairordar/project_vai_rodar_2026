# Vai Rodar - Deploys y carpetas oficiales

Este repo tiene mas de un frontend. Cada sitio Netlify debe apuntar a su carpeta oficial.

## 1. App usuario

- Carpeta oficial: `apps/user-app`
- Archivo principal: `apps/user-app/index.html`
- Contiene: app movil del usuario, assets, PWA, manifest y service worker
- Publish directory en Netlify: `apps/user-app`
- Build command: vacio

PWA:

- `apps/user-app/manifest.json`
- `apps/user-app/service-worker.js`
- `apps/user-app/assets/icon-*.png`

## 2. Cadastro actual de talleres

- Carpeta oficial: `apps/workshop-register-standalone`
- Archivo principal: `apps/workshop-register-standalone/index.html`
- Contiene: formulario publico actual de registro/cadastro de talleres
- Backend actual: `integrations/google-apps-script/Code.gs`
- Publish directory en Netlify: `apps/workshop-register-standalone`
- Build command: vacio

Este flujo es standalone por ahora. Existe para captar talleres antes de integrar todo a la app principal.

## 3. Cadastro futuro integrado

Cuando exista base de datos real en la app, el cadastro de talleres debe integrarse en:

- `apps/user-app`

En ese momento el boton "Cadastre sua Oficina" dejara de mandar a un link externo y abrira un flujo interno.

Hasta ese cambio, no duplicar ni reconstruir el formulario dentro de `apps/user-app`.

## 4. Backoffice futuro

- Backoffice talleres: `apps/workshop-backoffice`
- Backoffice admin Vai Rodar: `apps/admin-backoffice`
- Estado actual: carpetas preparadas, sin interfaz oficial todavia

## 5. Backend e integraciones

- Apps Script temporal: `integrations/google-apps-script/Code.gs`
- Supabase/backend futuro: `backend/supabase`

## 6. Carpetas no productivas

- `prototypes`: pruebas visuales e historico. No usar como publish directory.
- `exports`: artefactos antiguos, zips y capturas. No usar como fuente oficial.
- `archive`: material legado.

## Regla estable

No renombrar carpetas oficiales sin decision explicita del equipo:

- `apps/user-app`
- `apps/workshop-register-standalone`
- `apps/workshop-backoffice`
- `apps/admin-backoffice`
- `integrations/google-apps-script`
- `backend/supabase`

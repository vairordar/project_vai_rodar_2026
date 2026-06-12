# Vai Rodar

Repositorio principal del MVP Vai Rodar.

## Estructura estable

No renombrar estas carpetas sin una decision explicita del equipo. Claude, Codex y cualquier cowork deben trabajar sobre esta estructura.

```txt
project_vai_rodar_2026/
  apps/
    user-app/
    workshop-register-standalone/
    workshop-backoffice/
    admin-backoffice/

  integrations/
    google-apps-script/

  backend/
    supabase/

  docs/
  prototypes/
  exports/
  archive/
```

## Carpetas oficiales

- `apps/user-app/`: app principal del usuario. Aqui vive el frontend movil actual y la PWA.
- `apps/workshop-register-standalone/`: cadastro publico actual de talleres/oficinas. Es temporal/standalone y usa Apps Script.
- `apps/workshop-backoffice/`: futuro backoffice para talleres.
- `apps/admin-backoffice/`: futuro backoffice interno Vai Rodar.
- `integrations/google-apps-script/`: backend temporal del cadastro actual conectado a Google Sheets.
- `backend/supabase/`: backend futuro real con schema, servicios e integraciones Supabase.
- `docs/`: documentacion del proyecto.
- `prototypes/`: pruebas visuales e historico. No es produccion.
- `exports/`: zips, capturas y exports antiguos. No es fuente oficial.
- `archive/`: material legado.

## Regla de trabajo

El cadastro de talleres tiene dos estados:

- Actual: `apps/workshop-register-standalone/`, publicado aparte y conectado a `integrations/google-apps-script/`.
- Futuro: integrado dentro de `apps/user-app/` cuando exista base de datos real.

Mientras no integremos base de datos en la app, el boton "Cadastre sua Oficina" dentro de `apps/user-app/` debe seguir enviando al link externo del cadastro standalone.

Ver tambien `docs/deploy.md`.

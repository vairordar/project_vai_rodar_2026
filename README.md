# Vai Rodar

Repositorio principal del MVP Vai Rodar.

## Estructura estable

No renombrar estas carpetas sin una decision explicita del equipo. Claude, Codex y cualquier cowork deben trabajar sobre esta estructura.

```txt
project_vai_rodar_2026/
  apps/
    user-app/                    # App principal del usuario y PWA
    workshop-entry/              # Landing /oficinas
    workshop-register-supabase/  # Cadastro de oficinas/comercios con Supabase
    workshop-app/                # Backoffice de oficinas/comercios
    admin-backoffice/            # Backoffice interno Vai Rodar

  netlify/functions/             # Funciones serverless Netlify
  scripts/                       # Build local/Netlify
  supabase/migrations/           # Migraciones SQL ejecutables
  backend/supabase/              # Schema/base historica y utilidades backend
  integrations/                  # Integraciones legadas/temporales
  docs/                          # Documentacion del proyecto
  prototypes/                    # Pruebas visuales e historico, no produccion
  exports/                       # Artefactos antiguos, no fuente oficial
  archive/                       # Material legado
```

## Rutas de produccion en un dominio

Netlify ejecuta `npm run build`, genera `dist/` y publica estas rutas:

- `/`: `apps/user-app/`
- `/oficinas`: `apps/workshop-entry/`
- `/oficinas/cadastro`: `apps/workshop-register-supabase/`
- `/oficinas/painel`: `apps/workshop-app/`
- `/admin`: `apps/admin-backoffice/`

## Reglas de trabajo

- `dist/` es generado por build y no se debe editar como fuente principal.
- Los cambios deben hacerse en `apps/*`, `netlify/functions/*`, `scripts/*` o `supabase/migrations/*` segun corresponda.
- `prototypes/`, `exports/` y `archive/` no son produccion; sirven como historial y respaldo.
- No crear nuevas carpetas para flujos existentes sin actualizar este mapa.

Ver tambien `docs/deploy.md`.
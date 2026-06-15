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
- `supabase/migrations/`: SQL ejecutado o pendiente de ejecutar en Supabase.

## Variables Netlify necesarias

- `ADMIN_PASSWORD`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `OPENAI_API_KEY_VR`
- `APIBRASIL_BEARER_TOKEN`
- `APIBRASIL_HOMOLOG`

Opcional:

- `OPENAI_MODEL`

## Carpetas no productivas

- `prototypes/`: pruebas visuales e historico.
- `exports/`: zips, capturas y exports antiguos.
- `archive/`: material legado.
- `integrations/`: integraciones legadas/temporales.

Estas carpetas no entran al build de Netlify.
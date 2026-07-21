# Prompt Codex — Planes Grátis e Profissional (20/07/2026)

Trabaja en el repositorio canónico:
`C:\Users\joaqu\OneDrive\Documents\project_vai_rodar_2026`

## Contexto backend (ya construido, mismo push)

- Migración `supabase/migrations/20260720_planes_gratis_y_pro.sql`
  (el dueño la ejecuta en Supabase): tabla `plans` (catálogo oficial,
  lectura pública de activos), columnas `workshops.plan`
  ('free'|'pro'), `plan_price` (precio particular por cliente, null =
  precio oficial) y `plan_selected_at`.
- Regla de negocio YA activa en las vistas públicas: un taller
  **free** aprobado aparece en el mapa SIN suscripción/pago. El
  gating por suscripción queda solo para **pro**.
- `register-workshop.js` acepta `plan: 'free' | 'pro'` en el body y
  lo valida contra la tabla `plans` (400 si no existe/inactivo).
- `admin-data.js` devuelve `data.plansCatalog` (los planes con
  precio y beneficios) y `admin_workshops_overview` ahora trae
  `plan`, `plan_price`, `plan_selected_at`.
- `admin-action.js` acciones nuevas: `setWorkshopPlan {workshop_id,
  plan, custom_price?}` (custom_price null/'' = vuelve al precio
  oficial) y `updatePlanCatalog {code, name?, description?,
  price_monthly?, benefits?, active?}`.

Reglas fijas: no renombrar archivos, no editar `dist/`, no secrets
en HTML, errores reales visibles, commit solo archivos puntuales.

## PARTE A — Cadastro (`apps/workshop-register-supabase/index.html`)

Nueva sección "Escolha seu plano" ANTES del botón de enviar:

1. Al cargar, leer los planes:
   `sb.from('plans').select('code,name,description,price_monthly,benefits,sort_order').eq('active',true).order('sort_order')`
   (lectura pública, ya permitida por RLS).
2. Renderizar una tarjeta por plan, estilo selección (radio visual):
   - **Grátis**: "R$ 0/mês" + lista de `benefits`. **Seleccionado por
     defecto.**
   - **Profissional**: si `price_monthly` es null → badge **"Em
     breve"** y la tarjeta se muestra pero NO seleccionable (con
     texto "Disponivel em breve — comece no Gratis e faca upgrade
     depois"). Si tiene precio → "R$ X/mês" y seleccionable.
   - Los beneficios salen de `benefits` (array de strings), no
     hardcodear.
3. Enviar `plan: 'free' | 'pro'` en el body del POST a
   `register-workshop` junto con lo existente.
4. Si el catálogo de planes no carga: seguir con free por defecto y
   avisar en consola (no bloquear el registro por esto).
5. Mensaje bajo las tarjetas: "Sem cartao de credito. Voce pode
   mudar de plano quando quiser."

## PARTE B — Panel del taller (`apps/workshop-app/index.html`)

En la sección Conta, tarjeta "Seu plano":

- Mostrar el plan actual (`state.workshop.plan`): nombre, precio
  (usar `plan_price` del workshop si no es null, si no el
  `price_monthly` del catálogo; free = "R$ 0/mês") y beneficios.
- Si es free y el plan pro está "Em breve": texto "Plano
  Profissional em breve" sin botón de upgrade.
- Si pro tiene precio: botón "Fazer upgrade" que por ahora abre el
  chat/contacto con Vai Rodar (`sendAdminMessage` no aplica aquí;
  usar mailto o el canal existente) — el cobro es manual vía admin.

## PARTE C — Admin (`apps/admin-backoffice/index.html`)

1. En Comércios: columna/badge del plan en la tabla (Grátis /
   Profissional) y en el detalle todo-en-uno:
   - Plan actual, precio aplicado (particular si `plan_price` no es
     null, con indicación "preco particular"; si no, el oficial del
     catálogo), fecha de selección.
   - Botón **Modificar** → modal con: select de plan (free/pro) y
     campo "Preco particular (R$/mes)" opcional con ayuda "Vazio =
     preco oficial da tabela" → `setWorkshopPlan`.
2. Nueva tarjeta/panel "Planos" (puede vivir dentro de Comércios o
   en Visão geral): lista de `data.plansCatalog` con nombre, precio
   (null = "Em breve"), beneficios y estado; edición →
   `updatePlanCatalog`. Es acá donde el dueño fija el precio oficial
   del Pro cuando decida cobrarlo.
3. KPI simple donde quepa: cuántos comercios free vs pro.

## Criterios de aceptación

1. El cadastro muestra los dos planes desde la tabla `plans`; Grátis
   seleccionado por defecto; Pro "Em breve" no seleccionable
   mientras no tenga precio.
2. Registrar un taller free + aprobarlo en el admin → aparece en el
   mapa del user app SIN registrar ningún pago (validar de punta a
   punta).
3. El plan elegido queda en `workshops.plan` y visible en el admin.
4. "Modificar" en el admin cambia plan y precio particular, y el
   panel del taller refleja el precio correcto.
5. Editar el precio oficial del Pro en el catálogo lo actualiza en
   el cadastro (tras recargar).
6. Nada de datos demo; errores reales visibles.
7. `npm run build` sin errores; las 5 rutas responden.

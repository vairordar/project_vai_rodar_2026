# Prompt Codex — Rediseño Admin Backoffice Vai Rodar (14/07/2026)

## Contexto

Rediseño completo de `apps/admin-backoffice/index.html` (ÚNICO archivo a
tocar) a 9 módulos. El backend ya fue ampliado en
`netlify/functions/admin-data.js` y `netlify/functions/admin-action.js`
(cambios locales sin commit). Las acciones marcadas **[NUEVA]** se están
terminando en paralelo: cablearlas igual con el contrato indicado; todo
sale en el mismo deploy.

Las migraciones SQL de catálogo/bloqueos las ejecuta el dueño en Supabase;
no crear SQL desde el frontend.

**Reglas fijas:** no renombrar carpetas/archivos, no editar `dist/`, no
poner secrets en el HTML, errores de backend siempre visibles (nunca
éxito falso), commitear SOLO los archivos de este trabajo (nunca
`git add -A`: el repo tiene ruido CRLF).

## Qué preservar

- Gate de contraseña y helper `adminFetch` (header `X-Admin-Password`;
  GET `/.netlify/functions/admin-data`; POST
  `/.netlify/functions/admin-action` con `{action, payload}`).
- Estilo visual existente (variables CSS, `.panel`, `.table`, `.pill`,
  `.metric`, sidebar, menú mobile, botón Atualizar).
- La vista `view-overview` (Visão geral) se mantiene como está hoy; solo
  corregir sus contadores con los datasets nuevos.
- Las vistas de marketplace/analytics que salgan del menú NO se borran
  del archivo (quedan ocultas para recuperarlas después).

## Contrato de datos — respuesta de admin-data (`data.*`)

| Clave | Contenido |
| --- | --- |
| `adminUsers` | vista `admin_users_overview`: todos los usuarios (motoristas y dueños de taller), con email, teléfono, rol, fecha de registro, último login. |
| `vehicles` | todas las placas: `{id, user_id, plate, brand, model, year, color, created_at}`. |
| `plateLookups` **[NUEVA]** | caché FIPE por placa: `{plate, found, vehicle, raw, ...}` — `raw` es la respuesta completa de la API; mostrarla entera en el detalle de placa (render clave→valor recursivo, no JSON crudo). Cruzar por `plate`. |
| `workshops` | vista `admin_workshops_overview`: ficha completa del comercio (fiscal, contacto, estado, suscripción). |
| `subscriptions` / `payments` | suscripciones y pagos por `workshop_id` — usar DENTRO del detalle de cada comercio (vigencia, historial, registrar pago). |
| `workshopServices` | servicios cargados por cada taller (`*` + `workshops(name)`). |
| `serviceCategories` / `serviceSubcategories` | catálogo administrado, orden `sort_order`, flag `active`. |
| `serviceRequests` | solicitudes completas: `*` + `profiles(id,name,email,phone)` + `vehicles(brand,model,year,plate)` + `proposals(id,workshop_id,price,estimated_time,message,status,created_at,workshops(name))`. Incluye `home_service`, `selected_business_ids`, `expires_at`, `urgency`, `created_at`. |
| `reservations` | completas: `*` + `profiles(name,email)` + `workshops(name)`. Incluye `source`, `estimated_price`, `scheduled_at`, `status`, `created_at`. |
| `conversations` | `*` + `profiles(name,email)` + `workshops(name)`. |
| `messages` | `*` (con `conversation_id`, `sender_id`, texto, `created_at`), límite 3000 desc. Agrupar por `conversation_id`. |
| `workshopOffers` | ofertas con `workshops(name)`. |
| `auditLogs` | registro de acciones admin. |

## Contrato de acciones — admin-action

Respuesta siempre `{success:true,data}` o `{success:false,error}`.

**Existentes:** `setWorkshopVisibility {workshop_id, approval_status:
pending|approved|rejected|blocked, visible, open?}` ·
`createSubscriptionPayment {workshop_id, amount, plan_name?, duration_days?,
method?, reference?, invoice_url?, notes?}` · `setWorkshopOfferStatus
{offer_id, status: active|inactive}` · `reviewProfileChangeRequest` ·
`sendAdminMessage {recipient_type: user|workshop, recipient_id, title?,
message}` · `geocodeWorkshop {workshop_id}` · `updateWorkshopInfo
{workshop_id, ...campos}`.

**Catálogo (ya en el archivo local):**
`upsertServiceCategory {category_id?, name?, sort_order?, active?}` ·
`deleteServiceCategory {category_id}` (400 si está en uso → ofrecer
desactivar) · `upsertServiceSubcategory {subcategory_id?, category_id?,
name?, sort_order?, active?}` · `deleteServiceSubcategory
{subcategory_id, force?}` (si está en uso devuelve error con conteo;
confirmar y reintentar con `force:true`).

**[NUEVAS] (mismo deploy):**
`setUserBlocked {user_id, blocked:boolean, reason?}` — bloquea/desbloquea
el login del usuario · `setVehicleBlocked {vehicle_id, blocked:boolean,
reason?}` — la placa no podrá usarse en solicitudes nuevas ·
`deleteWorkshop {workshop_id}` — eliminación definitiva; el backend
devuelve error real si el comercio tiene historial (mostrar el mensaje y
sugerir bloqueo definitivo).

## Los 9 módulos del menú

### 1. Visão geral
Mantener el layout actual. Corregir KPIs con datos reales: usuarios
totales, comercios (aprobados/pendientes), solicitudes abiertas vs.
expiradas (`expires_at < now()`), propuestas, reservas confirmadas.
Alertas: comercios pendientes, cambios de perfil pendientes,
suscripciones vencidas.

### 2. Comércios
Pestañas internas: **Pendentes** · **Aprovados** · **Rejeitados e
bloqueados** · **Ofertas**.

- Pendentes: cada registro nuevo cae acá. Ficha completa + botones
  `Aprovar` (approval_status approved + visible true) y `Rejeitar`.
- Aprovados: botones `Modificar` (modal con `updateWorkshopInfo` +
  `geocodeWorkshop`), `Bloquear` (approval_status blocked → pasa a la
  pestaña de rechazados) y `Mensagem` (`sendAdminMessage` workshop).
- Rejeitados e bloqueados: badge que distinga `rejected` de `blocked`.
  Botones `Aprovar` (recuperar) y `Excluir definitivamente`
  (`deleteWorkshop`, con doble confirmación; si el backend devuelve
  error por historial, mostrarlo y ofrecer dejarlo bloqueado).
- Detalle todo-en-uno de cada comercio (expandible o modal): datos
  fiscales, contacto, dirección, coordenadas, logo, horarios
  (`schedule.custom`), `home_service`, servicios del catálogo
  (`workshopServices`), **suscripción vigente con fecha de vencimiento,
  historial de pagos y botón Registrar pago**
  (`createSubscriptionPayment`), fecha de registro.
- Ofertas: tabla de `workshopOffers` con comercio, título, vigencia,
  estado y botones Aprovar/Rejeitar (`setWorkshopOfferStatus`).

### 3. Usuários
Pestañas internas: **Todos** · **Placas** · **Bloqueados**.

- Todos: motoristas y dueños de taller juntos (badge de rol), con toda
  la información de `adminUsers`: nombre, email, teléfono, fecha de
  registro, último login, cantidad de vehículos y solicitudes. Botones:
  `Bloquear` (`setUserBlocked` con motivo opcional) y `Mensagem`.
- Placas: tabla de `vehicles` con placa, marca/modelo/año, color,
  **ID y nombre del motorista dueño**, fecha de registro. Al expandir
  una placa: TODA la información FIPE de `plateLookups.raw` (render
  legible clave→valor, incluyendo anidados). Botón `Bloquear placa`
  (`setVehicleBlocked`).
- Bloqueados: dos secciones — usuarios bloqueados y placas bloqueadas —
  con fecha y motivo del bloqueo y botón `Desbloquear` en cada fila.
  (Es una vista filtrada por el flag `blocked`, no otra tabla de datos.)

### 4. Catálogo
Gestión completa de categorías/subcategorías de servicios:

- Categorías ordenadas por `sort_order`: nombre editable inline, orden,
  toggle activo/inactivo, contador de subcategorías, contador de
  comercios que la usan (desde `workshopServices`), botón eliminar.
- Expandir categoría → subcategorías: nombre editable, orden, toggle
  activo, contador de uso, eliminar (confirmación con `force` si está
  en uso, mostrando el conteo que devuelve el backend).
- Formularios para crear categoría y subcategoría.
- Recargar datos tras cada acción exitosa.

### 5. Atividade
Pestañas internas: **Solicitações** · **Reservas**.

- Solicitações: cada `serviceRequest` como tarjeta con usuario,
  vehículo/placa, categoría, descripción, urgencia, badge `Dirigida`
  (si `selected_business_ids` no está vacío), badge `Expirada` (si
  `expires_at < now()`), `home_service`, fecha; debajo sus `proposals`
  anidadas: comercio, precio, plazo, mensaje, estado. Filtros: abiertas /
  expiradas / con propuestas / todas.
- Reservas: tabla completa con usuario, comercio, servicio, fecha
  agendada, origen (`source`), precio estimado, estado y fecha de
  creación. Filtros por estado.

### 6. Mensagens
Como pidió el dueño: tabla de comercios con contador de conversaciones y
botón `Ver conversas`. Al presionar → cards de cada chat de ese comercio
(usuario, fecha del último mensaje, cantidad de mensajes). Al abrir un
card → el hilo completo estilo chat de solo lectura, identificando quién
habla (comparar `sender_id` con `user_id` de la conversación). Botón
`Intervir como Vai Rodar` → `sendAdminMessage` al usuario o al comercio.

### 7. CRM WhatsApp
Placeholder estructurado (la API de WhatsApp Cloud se conecta después):
layout con lista de contactos vacía, panel de conversación deshabilitado
y aviso "Aguardando conexão com a API do WhatsApp Cloud". Sin lógica; solo
la estructura visual lista para cablear.

### 8. Exportações
Un card por cada tabla disponible (usuarios, placas, comercios,
servicios, categorías, solicitudes, propuestas, reservas, conversaciones,
mensajes, ofertas, suscripciones, pagos, auditoría) con botón
`Baixar CSV`. Generación client-side desde los datasets ya cargados,
UTF-8 con BOM para que Excel abra acentos bien. Todas incluyen la fecha
de registro.

### 9. Auditoria
Mantener como está (tabla de `auditLogs`).

## Criterios de aceptación

1. Un comercio recién registrado aparece en Pendentes; aprobar lo mueve a
   Aprovados y lo hace visible en el user app; bloquear lo mueve a
   Rejeitados; desde ahí se puede recuperar o eliminar definitivo.
2. El detalle del comercio muestra suscripción, vencimiento e historial
   de pagos, y permite registrar un pago manual.
3. Bloquear un usuario/placa lo mueve a la pestaña Bloqueados con motivo
   y fecha, y desbloquear lo restaura.
4. El detalle de una placa muestra la respuesta FIPE completa legible.
5. Catálogo: crear/editar/desactivar/eliminar persiste en Supabase; los
   errores de "en uso" se muestran tal cual llegan del backend.
6. Atividade muestra solicitudes con propuestas anidadas y todas las
   reservas con su estado.
7. Mensagens permite leer cualquier chat completo por comercio.
8. Exportações descarga CSV correcto de cada tabla.
9. Ninguna sección muestra datos demo; vacío = mensaje de vacío.
10. `npm run build` sin errores; las 5 rutas responden; `/admin` sigue
    pidiendo contraseña.

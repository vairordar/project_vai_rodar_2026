# Prompt Codex — CRM WhatsApp (admin) + Onboarding del backoffice (20/07/2026)

Trabaja en el repositorio canónico:
`C:\Users\joaqu\OneDrive\Documents\project_vai_rodar_2026`

## Contexto backend (ya construido, sale en el mismo push)

- Migración `supabase/migrations/20260720_crm_whatsapp_y_onboarding.sql`
  (el dueño la ejecuta en Supabase): tablas `crm_contacts`,
  `crm_messages`, `crm_templates` + columnas
  `workshops.onboarding_state` (jsonb) y `onboarding_completed_at`.
- Funciones nuevas: `netlify/functions/whatsapp-webhook.js` (recepción
  Meta) y `netlify/functions/whatsapp-send.js` (envío, protegido con
  X-Admin-Password). Sin las variables de Meta configuradas, el envío
  devuelve 503 con mensaje claro — la UI debe mostrarlo tal cual
  ("modo preparación").
- `admin-data.js` ahora devuelve: `crmContacts` (con `workshops(name)`),
  `crmMessages` (agrupar por `contact_id`), `crmTemplates`.
- `admin-action.js` acciones nuevas: `upsertCrmContact`,
  `deleteCrmContact`, `importCrmContacts`, `upsertCrmTemplate`,
  `deleteCrmTemplate`.
- Guía de Meta: `docs/guia-configuracion-whatsapp-cloud.md`.

Reglas fijas: no renombrar archivos, no editar `dist/`, no secrets en
HTML, errores reales visibles, commit solo de archivos puntuales
(nunca `git add -A`).

## PARTE A — Módulo CRM WhatsApp en `apps/admin-backoffice/index.html`

Reemplazar el placeholder actual de CRM WhatsApp por el módulo real,
con tres pestañas:

### A1. Contatos (pipeline de prospección)

- Tabla desde `data.crmContacts`: negocio (`business_name`), contacto
  (`name`), teléfono, ciudad/UF, estado del pipeline (pill), tags,
  último mensaje (`last_message_preview` + fecha), fecha de registro.
- Filtro por estado del pipeline: `new` (Novo) → `contacted`
  (Contatado) → `interested` (Interessado) → `negotiating`
  (Negociando) → `registered` (Cadastrado) → `not_interested` /
  `invalid`. Cambiar estado inline → `upsertCrmContact
  {contact_id, status}`.
- Alta manual (modal): teléfono obligatorio formato `+55DDDNÚMERO`,
  nombre, negocio, ciudad, UF, notas → `upsertCrmContact`.
- Importación masiva: textarea "un contacto por línea" formato
  `telefone;nome;negocio;cidade;UF` → parsear → `importCrmContacts
  {contacts:[...]}` → mostrar el resumen que devuelve (insertados,
  duplicados, inválidos).
- Si `workshop_id` no es null: badge "Cadastrado na plataforma" con
  el nombre del taller.
- Botón eliminar con confirmación → `deleteCrmContact`.

### A2. Conversas (hilo por contacto)

- Al abrir un contacto: hilo estilo chat con sus `crmMessages`
  (filtrar por `contact_id`, orden asc). Entrantes a la izquierda,
  salientes a la derecha con su estado (queued/sent/delivered/read/
  failed — mostrar el `error` si failed).
- Caja de envío con dos modos:
  - **Texto libre**: POST a `/.netlify/functions/whatsapp-send` con
    header `X-Admin-Password` (mismo mecanismo que adminFetch) y body
    `{contact_id, text}`. Aviso visible: "Texto livre so chega dentro
    da janela de 24h apos a ultima resposta do contato".
  - **Template**: select de `crmTemplates` activos con
    `meta_status='approved'`; inputs para los parámetros `{{n}}`
    detectados en el body; enviar
    `{contact_id, template_name, template_params:[...]}`.
- Respuesta 503 del envío (Meta no configurado): mostrar el mensaje
  del backend con link visual a la guía. NO ocultar el error.
- Tras envío exitoso: recargar datos.

### A3. Templates

- Tabla de `crmTemplates`: nombre, idioma, body (preview), estado Meta
  (pill: draft/pending/approved/rejected), activo.
- Crear/editar (modal): nombre EXACTO de Meta, idioma (default pt_BR),
  body con `{{1}}, {{2}}`, estado Meta manual → `upsertCrmTemplate`.
- Eliminar → `deleteCrmTemplate`.
- Nota fija en la UI: "Para iniciar conversa e obrigatorio um template
  aprovado no WhatsApp Manager (ver guia)."

## PARTE B — Onboarding en `apps/workshop-app/index.html`

### B1. Tour guiado (primera entrada)

- Al cargar el panel con sesión válida: si
  `state.workshop.onboarding_completed_at` es null → iniciar tour.
- Tour = overlay oscuro + tarjeta flotante anclada a cada sección, con
  título, texto corto (pt-BR), contador "Passo X de 7" y botones
  Anterior / Próximo / Pular tour. Pasos:
  1. **Solicitações** — "Aqui chegam os pedidos de motoristas da sua
     região. Responda rápido para ganhar mais clientes."
  2. **Propostas** — "Envie preço, prazo e como o cliente agenda.
     Propostas valem por até 15 dias."
  3. **Mensagens** — "Converse com os motoristas e envie o botão de
     criar reserva."
  4. **Agenda e Reservas** — "Confirme horários, bloqueie dias e
     gerencie sua capacidade."
  5. **Perfil público** — "Logo, horários e serviços aparecem no app
     do motorista. Complete tudo para se destacar."
  6. **Ofertas** — "Publique promoções. Elas passam por aprovação da
     Vai Rodar antes de ir ao ar."
  7. **Receber pedidos** — "Use este botão para pausar novos pedidos
     quando a oficina estiver lotada."
- Al terminar o saltar: `sb.from('workshops').update({
  onboarding_completed_at: new Date().toISOString(),
  onboarding_state: {...state, tour_done: true} }).eq('id', workshopId)`
  (la policy del dueño ya lo permite). Guardar también el paso actual
  en `onboarding_state.tour_step` si abandona a mitad.
- Botón "Rever tour" en la sección Conta para relanzarlo.

### B2. Checklist de perfil (persistente)

Tarjeta "Complete seu perfil" arriba del dashboard, calculada EN VIVO
con datos reales (no se guarda en DB):

| Paso | Completo cuando |
| --- | --- |
| Suba seu logo | `workshop.photo_url` no vacío |
| Configure seus horários | `workshop.schedule.custom` no vacío |
| Escolha suas categorias | tiene filas en `workshop_categories` (o `services.length > 0`) |
| Cadastre serviços com preço | tiene filas en `workshop_services` |
| Publique sua primeira oferta | tiene filas en `workshop_offers` |

- Barra de progreso X/5; cada ítem pendiente es clickeable y lleva a
  la sección correspondiente.
- Al 5/5: mostrar "Perfil completo!" y permitir ocultar la tarjeta →
  `onboarding_state.checklist_dismissed = true` (persistir con el
  mismo UPDATE). Si está dismissed pero vuelve a faltar algo
  (ej. borró el logo), volver a mostrarla.

## Criterios de aceptación

1. CRM: alta manual, importación masiva con resumen, cambio de estado
   del pipeline y notas persisten en Supabase.
2. CRM: con Meta sin configurar, el envío muestra el error 503 real y
   el resto del módulo funciona igual.
3. CRM: templates CRUD completo con estados de Meta.
4. Onboarding: taller nuevo ve el tour una sola vez; "Pular" también
   lo marca completado; "Rever tour" lo relanza.
5. Checklist calcula el progreso real y cada ítem navega a su sección;
   se puede ocultar al completar.
6. Nada de datos demo; vacío = mensaje de vacío.
7. `npm run build` sin errores; las 5 rutas responden.

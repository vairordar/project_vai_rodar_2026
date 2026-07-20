# Contrato frontend — Flujo propuesta → aceptación → reserva (20/07/2026)

Backend: `supabase/migrations/20260720_flujo_propuesta_reserva.sql` +
`netlify/functions/notify-event.js` (evento nuevo `reservation_flow`).
Construido sobre los triggers de aceptación atómica del 17/07.

## 1. Columnas nuevas

### `proposals` (la oficina define al enviar)

| Columna | Tipo | Valores | Notas |
| --- | --- | --- | --- |
| `booking_mode` | text | `scheduled` \| `dropoff` \| `walkin` | Si el frontend no lo envía, el trigger pone `scheduled`. |
| `estimated_duration_text` | text | libre ("2 horas", "3 dias") | NO bloquea agenda. `estimated_time` sigue existiendo (compat). |
| `booking_instructions` | text | libre, opcional | Llegada, condiciones, diagnóstico. |
| `validity_days` | integer | 3 \| 5 \| 7 \| 15 | Default 5. |
| `valid_until` | timestamptz | calculado | SIEMPRE lo calcula el trigger: `created_at + validity_days`. No enviarlo. |

El INSERT de propuesta desde el panel del taller solo agrega estos campos
al insert actual. El motorista no puede modificar ninguno (guard en DB).
Una propuesta con `valid_until <= now()` ya no puede aceptarse (la UI
debe mostrarla como "vencida").

### `reservations`

| Columna | Notas |
| --- | --- |
| `request_id`, `proposal_id` | vínculos al origen (pueden ser null en reservas manuales/viejas). |
| `booking_mode` | heredado de la propuesta. |
| `estimated_duration_text`, `booking_instructions` | heredados. |
| `scheduled_at` | AHORA NULLABLE: null hasta que el motorista elija horario (`scheduled`/`dropoff`). `walkin` queda null siempre. |
| `confirmed_at`, `cancelled_at`, `completed_at`, `cancel_reason` | timestamps/motivo del ciclo. |
| `estimated_price` | copiado de `proposals.price`. |

## 2. RPCs (llamar con `sb.rpc(nombre, params)`)

Todas devuelven `jsonb` con `{ success: true, reservation: {...} }` o
lanzan error con mensaje claro en pt-BR (mostrar `error.message` tal cual).

### `accept_proposal({ p_proposal_id })`
Solo el motorista dueño de la solicitud. Acepta la propuesta (los
triggers cierran la solicitud y rechazan las demás), crea UNA reserva
vinculada y notifica. **Idempotente**: repetir la llamada devuelve la
misma reserva (`accepted: false` en la repetición).

```json
{ "success": true, "accepted": true,
  "request_id": "…", "proposal_id": "…",
  "reservation": { "id": "…", "status": "pending", "scheduled_at": null,
                   "booking_mode": "scheduled", "estimated_price": 350, … } }
```

Errores típicos: propuesta vencida, solicitud expirada, otra propuesta ya
aceptada, no sos el dueño.

UI post-aceptación según `reservation.booking_mode`:
- `scheduled` → abrir selector de fecha y hora ("Escolha data e horario").
- `dropoff` → abrir selector solo para la entrega del vehículo.
- `walkin` → NO pedir fecha; mostrar `booking_instructions` ("Va ate a
  oficina conforme as instrucoes").

### `request_reservation_slot({ p_reservation_id, p_scheduled_at })`
Solo el motorista, solo reservas `pending` de tipo `scheduled`/`dropoff`.
`p_scheduled_at` en ISO con timezone (ej. `2026-07-22T14:00:00-03:00`).
Valida: fecha futura, horario de atención del taller (`schedule.custom`),
bloqueos de agenda y capacidad por franja (`slot_minutes` ×
`max_bookings_per_slot`). En `dropoff` solo la hora de llegada consume
capacidad. Deja la reserva `pending` esperando confirmación del taller.

### `confirm_reservation({ p_reservation_id })`
Solo el dueño del taller. `pending` → `confirmed` (+`confirmed_at`).
Exige horario elegido (salvo walk-in) y revalida capacidad.

### `complete_reservation({ p_reservation_id })`
Solo el dueño del taller. `pending`/`confirmed` → `completed`
(+`completed_at`).

### `cancel_reservation({ p_reservation_id, p_reason })`
Motorista dueño O taller. `pending`/`confirmed` → `cancelled`
(+`cancelled_at`, `cancel_reason`). Notifica a la contraparte.

## 3. Estados de la reserva

`pending` (creada, esperando horario y/o confirmación) → `confirmed` →
`completed`. Desde `pending`/`confirmed` se puede ir a `cancelled`.
Sub-estado visual para `pending`: si `scheduled_at` es null y el modo no
es walk-in → "Aguardando horario do motorista"; si tiene fecha →
"Aguardando confirmacao da oficina".

## 4. Notificaciones y push

Las RPCs crean SIEMPRE la notificación interna (tabla `notifications`)
para: proposta aceita (taller), reserva criada (motorista), horario
solicitado (taller), confirmada (motorista), cancelada (contraparte),
concluida (motorista). **No insertar notificaciones manualmente para
estos eventos.**

Para el push, después de cada RPC exitosa llamar a la función Netlify
existente (con el Bearer del usuario logueado):

```js
fetch('/.netlify/functions/notify-event', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}` },
  body: JSON.stringify({
    event: 'reservation_flow',
    reservationId: reservation.id,
    flowEvent: 'proposal_accepted' // o: reservation_created,
    // reservation_time_requested, reservation_confirmed,
    // reservation_cancelled, reservation_completed
  })
});
```

Este evento hace SOLO push (sin duplicar la notificación interna) y
elige el destinatario según el evento. Tras aceptar, disparar dos:
`proposal_accepted` y `reservation_created`. El evento legacy
`reservation_status_changed` sigue funcionando para el flujo viejo del
panel del taller; para el flujo nuevo usar `reservation_flow`.

## 5. Guardas activas en la base (para no pelearse con ellas)

- El motorista NO puede editar precio, mensaje, duración, instrucciones,
  modalidad ni validez de una propuesta (solo aceptar/recusar).
- El motorista solo puede: elegir horario mientras `pending` y cancelar.
  No puede confirmarse ni completarse a sí mismo una reserva.
- Aceptar dos veces jamás duplica la reserva (índice único por
  `proposal_id`).
- La policy legacy "Partes atualizam reserva" (cualquier autenticado
  actualizaba cualquier reserva) fue eliminada y reemplazada por
  policies por dueño.

## 6. Compatibilidad

- `proposals.estimated_time` (texto libre actual) sigue intacto; las
  propuestas viejas quedaron backfilled como `scheduled` + 5 días.
- Reservas manuales del taller y el flujo directo "Agendar reserva" del
  user app siguen funcionando (sus policies no cambiaron).
- El vencimiento de 3 días de `service_requests` no se tocó.
- El lifecycle/metricas del 17/07 (`request_lifecycle_events`,
  `admin_request_lifecycle`, etc.) se conservan; la aceptación vía RPC
  pasa por los mismos triggers y queda registrada igual.

## 7. Estado de implementacion (20/07/2026)

- `apps/workshop-app/index.html` guarda modalidad, duracion, instrucciones
  y validez; tambien confirma, concluye y cancela reservas mediante RPC.
- `apps/user-app/index.html` acepta propuestas mediante `accept_proposal`,
  solicita horario cuando corresponde y muestra el ciclo real de reservas.
- `netlify/functions/notify-event.js` soporta `reservation_flow` sin
  duplicar las notificaciones internas creadas por Supabase.
- La migration versionada es
  `supabase/migrations/20260720_flujo_propuesta_reserva.sql`.
- El JavaScript inline de ambos frontends y las Netlify Functions fueron
  validados antes del deploy; `npm run build` genero correctamente las
  rutas `/`, `/oficinas`, `/oficinas/cadastro`, `/oficinas/painel` y
  `/admin`.

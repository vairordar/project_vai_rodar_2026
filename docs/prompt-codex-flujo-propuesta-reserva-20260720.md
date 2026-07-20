# Prompt Codex — Conectar flujo propuesta → aceptación → reserva (20/07/2026)

Trabaja en el repositorio canónico:
`C:\Users\joaqu\OneDrive\Documents\project_vai_rodar_2026`

## Contexto

El backend está DESPLEGADO Y VERIFICADO en Supabase (migración
`20260720_flujo_propuesta_reserva.sql` aplicada; columnas, 9 funciones,
backfill e índice anti-duplicados confirmados en producción).

**Contrato completo y obligatorio:**
`docs/contrato-flujo-propuesta-reserva-20260720.md`
Leerlo entero antes de editar. Nombres de columnas, firmas de RPC,
estados, ejemplos JSON y reglas de push están ahí. No inventar nada
fuera de ese contrato.

Cambios locales sin commit que salen en el mismo push (no tocarlos):
`netlify/functions/notify-event.js` (evento nuevo `reservation_flow`),
`admin-data.js`, `admin-action.js`, `register-workshop.js`.

## Archivos a modificar (SOLO estos dos)

1. `apps/workshop-app/index.html` — panel del taller
2. `apps/user-app/index.html` — app del motorista

Reglas fijas: no renombrar archivos, no editar `dist/`, no secrets en
HTML, errores reales visibles (nunca éxito falso), commit solo de
archivos puntuales (nunca `git add -A`, el repo tiene ruido CRLF).

## PARTE A — Panel del taller (`apps/workshop-app/index.html`)

### A1. Formulario de propuesta ampliado

Al modal "Enviar proposta" existente, agregar 4 campos que se guardan
en el INSERT de `proposals`:

- **Modalidade** (radio/select, obligatorio, default `scheduled`):
  - `scheduled` → "Cliente agenda data e horario"
  - `dropoff` → "Cliente agenda so a entrega do veiculo"
  - `walkin` → "Cliente pode chegar sem reserva"
  → columna `booking_mode`
- **Duracao estimada** (texto libre, opcional, ej. "2 horas", "3 dias")
  → columna `estimated_duration_text`. NO tocar `estimated_time`
  existente (sigue igual por compatibilidad).
- **Instrucoes para o cliente** (textarea opcional)
  → columna `booking_instructions`
- **Validade da proposta** (select: 3, 5, 7, 15 dias; default 5)
  → columna `validity_days`. NO enviar `valid_until` (lo calcula la DB).

### A2. Reservas con los estados nuevos

En la vista de reservas del panel:

- Mostrar `booking_mode` (badge: Agendado / Entrega / Walk-in),
  `estimated_duration_text`, `booking_instructions` y el vínculo a la
  solicitud (`request_id` no null = viene del flujo de propuestas).
- Reserva `pending` sin `scheduled_at` (no walk-in): mostrar
  "Aguardando horario do motorista" — sin botón Confirmar todavía.
- Reserva `pending` con `scheduled_at`: botón **Confirmar** →
  `sb.rpc('confirm_reservation', { p_reservation_id: id })`.
- Reserva `confirmed`: botón **Concluir servico** →
  `sb.rpc('complete_reservation', { p_reservation_id: id })`.
- Botón **Cancelar** (en pending/confirmed) con prompt de motivo →
  `sb.rpc('cancel_reservation', { p_reservation_id: id, p_reason: motivo })`.
- Tras cada RPC exitosa: recargar reservas + disparar el push con
  `notify-event` evento `reservation_flow` (flowEvent según acción:
  `reservation_confirmed`, `reservation_completed`,
  `reservation_cancelled`) como indica el contrato.
- Los updates directos legacy de reservas manuales del taller siguen
  funcionando; usar las RPCs SOLO para reservas del flujo
  (con `proposal_id` no null). Mostrar el `error.message` de la RPC tal
  cual (viene en pt-BR).

### A3. Propuestas enviadas

En la lista de propuestas del taller, mostrar la validez: badge
"Valida ate DD/MM" con `valid_until`, y "Vencida" si `valid_until <= now`.

## PARTE B — User app (`apps/user-app/index.html`)

### B1. Card de propuesta en "Minhas propostas"

- Mostrar modalidad (texto legible), `estimated_duration_text`,
  `booking_instructions` (si existe) y "Valida ate DD/MM/YYYY"
  (`valid_until`).
- Si `valid_until <= now` y status `pending`: mostrar como **Vencida**,
  deshabilitar el botón de aceptar.

### B2. Aceptar propuesta por RPC

Reemplazar el mecanismo actual de aceptación (update directo de
`proposals.status`) por:

```js
const { data, error } = await sb.rpc('accept_proposal', { p_proposal_id: id });
```

- Si `error`: mostrar `error.message` tal cual.
- Si ok: `data.reservation` trae la reserva creada. Disparar push
  `reservation_flow` con `proposal_accepted` y `reservation_created`.
- Según `data.reservation.booking_mode`:
  - `scheduled` → abrir selector de fecha+hora ("Escolha data e horario
    do atendimento").
  - `dropoff` → mismo selector con título "Escolha o horario de entrega
    do veiculo".
  - `walkin` → NO pedir fecha; mostrar `booking_instructions` con
    mensaje "Va ate a oficina conforme as instrucoes".

### B3. Selector de horario

Al confirmar fecha+hora del selector:

```js
const { data, error } = await sb.rpc('request_reservation_slot', {
  p_reservation_id: reservationId,
  p_scheduled_at: fechaISOConTimezone  // ej. '2026-07-22T14:00:00-03:00'
});
```

- La DB valida: fecha futura, horario de atención del taller, bloqueos
  y capacidad. Si falla, mostrar `error.message` (explica el motivo:
  día cerrado, franja llena, etc.) y dejar elegir otro horario.
- Si ok: push `reservation_flow` con `reservation_time_requested` y
  mostrar "Aguardando confirmacao da oficina".
- El selector debe poder reabrirse desde la reserva mientras esté
  `pending` (cambiar horario elegido).

### B4. Estado de reservas del motorista

En la vista de reservas: estados legibles —
`pending` sin fecha → "Escolha o horario" (botón que abre el selector);
`pending` con fecha → "Aguardando confirmacao";
`confirmed` → "Confirmada para DD/MM HH:MM";
`completed` → "Concluida"; `cancelled` → "Cancelada" (+ motivo).
Botón **Cancelar** (pending/confirmed) con motivo →
`cancel_reservation` + push `reservation_cancelled`.

### B5. No duplicar notificaciones

Las RPCs YA crean las notificaciones internas. Eliminar cualquier
insert manual en `notifications` para estos eventos y cualquier llamada
al evento legacy `proposal_accepted` de notify-event en el flujo nuevo.
Solo usar `reservation_flow` (push-only) como indica el contrato.

## Qué NO tocar

- El flujo directo "Agendar reserva" desde el card de la oficina
  (reserva sin propuesta) sigue como está.
- Reservas manuales del taller.
- `proposals.estimated_time` y su render actual.
- El CTA `[RESERVA_CTA]` de mensajes.

## Criterios de aceptación

1. Taller envía propuesta con modalidad/duración/instrucciones/validez
   → llegan a la DB en las columnas nuevas.
2. Motorista acepta → solicitud cerrada, demás propuestas rechazadas,
   UNA reserva creada. Aceptar dos veces (doble click) no duplica nada.
3. Propuesta vencida no se puede aceptar y se ve como "Vencida".
4. `scheduled`/`dropoff`: selector de horario respeta horario de
   atención, bloqueos y capacidad (los errores de la DB se muestran).
5. `walkin`: sin selector; instrucciones visibles; el taller puede
   concluirla directamente.
6. Confirmar/Concluir/Cancelar funcionan desde el panel del taller y
   el estado se refleja en la app del motorista.
7. Cada paso genera su notificación interna (una sola) y su push.
8. `npm run build` sin errores; las 5 rutas responden.

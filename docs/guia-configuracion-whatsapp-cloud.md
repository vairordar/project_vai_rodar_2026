# Guía — Configurar WhatsApp Cloud API para el CRM Vai Rodar

El CRM ya está construido y desplegable SIN esta configuración (modo
preparación: contactos, notas, plantillas e importación funcionan).
El envío y la recepción de mensajes se activan al completar esta guía.

## 1. Requisitos en Meta

1. Cuenta en https://business.facebook.com (Meta Business Suite) con
   el negocio **Vai Rodar** creado y, idealmente, verificado
   (la verificación del negocio sube los límites de envío).
2. Un número de teléfono que NO esté usado en WhatsApp/WhatsApp
   Business App (el número queda vinculado a la API en exclusiva).
   Puede ser un chip nuevo o número virtual brasileño.

## 2. Crear la app y obtener credenciales

1. https://developers.facebook.com → **Create App** → tipo **Business**.
2. En el panel de la app → **Add product** → **WhatsApp** → Set up.
3. En **WhatsApp → API Setup** vas a ver:
   - **Phone number ID** → esta es `WHATSAPP_PHONE_NUMBER_ID`
   - Un token temporal de prueba (dura 24h). Para producción:
4. Token permanente: **Business Settings → Users → System users** →
   crear system user (rol Admin) → **Generate token** → seleccionar la
   app → permisos `whatsapp_business_messaging` y
   `whatsapp_business_management` → copiar el token
   → este es `WHATSAPP_TOKEN`.
5. Registrar el número real: **WhatsApp → API Setup → Add phone
   number**, seguir la verificación por SMS/llamada.

## 3. Configurar el webhook

1. Inventá una clave secreta cualquiera (ej. generada al azar)
   → esta es `WHATSAPP_VERIFY_TOKEN`.
2. Primero cargá las variables en Netlify (paso 4) y deployá, porque
   Meta valida el webhook al guardarlo.
3. En la app de Meta: **WhatsApp → Configuration → Webhook** → Edit:
   - Callback URL: `https://vairodar.com.br/.netlify/functions/whatsapp-webhook`
   - Verify token: el mismo valor de `WHATSAPP_VERIFY_TOKEN`
   - Guardar (Meta hace un GET de verificación; debe dar verde)
4. En **Webhook fields** suscribirse a: `messages` (incluye estados).

## 4. Variables en Netlify (Site settings → Environment variables)

| Variable | Valor |
| --- | --- |
| `WHATSAPP_TOKEN` | token permanente del system user |
| `WHATSAPP_PHONE_NUMBER_ID` | Phone number ID del paso 2.3 |
| `WHATSAPP_VERIFY_TOKEN` | la clave secreta que inventaste |
| `WHATSAPP_GRAPH_VERSION` | (opcional) default `v20.0` |

Después de agregarlas: **redeploy** del sitio para que las funciones
las tomen. Nunca poner estos valores en el HTML ni en el repo.

## 5. Plantillas (obligatorias para prospección)

Regla de Meta: solo se puede escribir libremente a un contacto dentro
de las **24 horas** posteriores a su último mensaje. Para INICIAR una
conversación (prospección en frío) es obligatorio usar una **plantilla
aprobada por Meta**.

1. Crear en **WhatsApp Manager → Message templates** → categoría
   **Marketing**, idioma **pt_BR**. Ejemplo:
   > Olá {{1}}! Somos da Vai Rodar, a plataforma que conecta oficinas
   > de São Paulo a motoristas que precisam de serviços. Sua oficina
   > {{2}} pode receber solicitações de clientes da região sem custo
   > inicial. Posso te contar como funciona?
2. Esperar la aprobación (minutos a 48h).
3. Registrar la plantilla en el CRM (módulo CRM WhatsApp → Templates)
   con el **nombre exacto** de Meta y marcar `meta_status = approved`.
4. Enviar: el CRM la usa vía `whatsapp-send` con `template_name` y
   los parámetros `{{1}}, {{2}}...` en orden.

## 6. Prueba de humo

1. Con todo configurado, agregá tu propio número como contacto en el
   CRM y enviate la plantilla → debe llegar al WhatsApp.
2. Respondé desde tu WhatsApp → el mensaje debe aparecer en el hilo
   del contacto en el CRM (webhook funcionando) y el estado del
   enviado debe pasar a `delivered`/`read`.

## Límites a tener en cuenta

- Cuenta nueva sin verificar: ~250 conversaciones iniciadas/día;
  con negocio verificado sube por niveles (1k → 10k → 100k).
- Respuestas de prospectos abren ventana de 24h para texto libre.
- Meta cobra por conversación iniciada (categoría Marketing);
  revisar precios de Brasil en la documentación de Meta.

# n8n Workflows Showcase

> Coleccion de workflows de automatizacion construidos con n8n, IA y APIs externas. Cada uno resuelve un problema concreto de e-commerce / atencion al cliente / generacion de demanda y se publica con codigo, arquitectura y notas de implementacion.

Los workflows aqui presentados estan **construidos desde cero como demos generalizadas** — no son codigo de proyectos bajo contrato. Las "tiendas" y "clientes" mencionados (ACME Store, ACME Corp) son ficticios y los datos son sinteticos.

---

## Workflows incluidos

### 🛒 [E-commerce Product Search Bot](./workflows/e-commerce-product-search-bot)
Chatbot de busqueda de productos para WooCommerce con OpenAI + post-procesador anti-hallucination. Detecta intencion (marca / categoria / texto libre), consulta la WooCommerce Store API, filtra por precio/stock, y devuelve los resultados al cliente con marcadores estructurados que el frontend renderiza como cards.

**Stack:** n8n · OpenAI GPT-4 · WooCommerce Store API · JavaScript en Code nodes

### 💬 [WhatsApp Booking System](./workflows/whatsapp-booking-system)
Sistema de reservas conversacional via WhatsApp. El agente captura intencion, propone slots disponibles consultando Google Calendar, confirma con el cliente y crea el evento. Recordatorios automaticos 24h y 2h antes del turno.

**Stack:** n8n · Evolution API · Google Calendar · OpenAI · Postgres (memoria)

### 🔄 [Multi-store Inventory Sync](./workflows/multi-store-inventory-sync)
Sincronizacion bidireccional de stock entre WooCommerce y Odoo. Cada cambio en uno se propaga al otro via webhooks + JSON-RPC, con cola anti-duplicacion y reconciliacion nocturna.

**Stack:** n8n · WooCommerce REST API · Odoo JSON-RPC · Postgres (cola/log)

### 📞 [Voice AI Lead Qualifier](./workflows/voice-ai-lead-qualifier)
Llamadas salientes automaticas para calificacion de leads. n8n dispara la llamada via Retell AI, el agente conversacional captura intencion + presupuesto + timing, y el resultado se persiste en CRM con score y proxima accion sugerida.

**Stack:** n8n · Retell AI · OpenAI · CRM REST API

---

## Como usar este repo

Cada subcarpeta es independiente y contiene:

- `workflow.json` — exportable a n8n via *Settings → Import from File*
- `README.md` — problema, arquitectura, decisiones, replica
- `.env.example` — variables de entorno necesarias
- `screenshots/` — canvas, ejemplos de ejecucion (cuando aplica)

Para correr localmente cualquiera de ellos:

1. Levantar n8n self-hosted (`docker-compose up` con la imagen oficial sirve).
2. Importar el `workflow.json` del workflow elegido.
3. Configurar las credenciales en n8n (OpenAI, WooCommerce, etc.).
4. Copiar `.env.example` a `.env.local` y completar.
5. Activar el workflow.

## Decisiones generales

- **n8n self-hosted**, no n8n Cloud. Da control total sobre datos, ejecuciones y costos.
- **Workflows pequenos y desacoplados** sobre uno monolitico. El router separa intenciones; cada subworkflow hace una cosa bien.
- **Memoria conversacional en Postgres**, no en RAM. Sobrevive a restarts y permite analisis posterior.
- **Code nodes con materializacion de proxies** (`JSON.parse(JSON.stringify(x))`) para evitar timeout del Task Runner cuando hay objetos anidados.
- **Switch v3 con `conditions.options` completo** (caseSensitive / leftValue / typeValidation / version) para evitar el bug "Cannot read properties of undefined".

## Licencia

MIT — ver [LICENSE](./LICENSE).

## Autor

**Luis Molina Reinoso** — AI & Automation Engineer
San Miguel de Tucuman, Argentina

[LinkedIn](https://linkedin.com/in/luis-molina-171190) · [GitHub](https://github.com/luis171190)

¿Disponibilidad para proyectos? Mis areas: integraciones n8n, chatbots WhatsApp, voice AI, sincronizaciones multi-sistema, dashboards Power BI / Tableau.

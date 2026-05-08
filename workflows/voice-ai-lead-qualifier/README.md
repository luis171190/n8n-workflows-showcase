# 📞 Voice AI Lead Qualifier

> Llamadas salientes automaticas para calificacion de leads con Retell AI + n8n.

🚧 **En construccion** — workflow en desarrollo. Volve pronto.

## Que hara cuando este listo

- Recibira un nuevo lead (HTTP webhook desde landing / formulario).
- Disparara una llamada saliente via **Retell AI** con un agente conversacional configurado.
- El agente capturara: intencion / presupuesto / timing / nivel de decision.
- Al finalizar la llamada, persistira el resultado en CRM con score (1-10) y proxima accion sugerida.

## Stack previsto

n8n · Retell AI · OpenAI · CRM REST API (Hubspot / Pipedrive / Close)

---

[← Volver al indice](../../README.md)

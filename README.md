# Claude Code API Proxy

## Cosa è

Un proxy locale che espone un endpoint **Anthropic Messages API** (`/v1/messages`) compatibile, usando internamente `claude -p` (headless mode) come backend. Permette a qualsiasi tool che parla il protocollo Anthropic di usare la subscription MAX di Claude Code senza una API key separata.

## Perché

La subscription **Anthropic MAX** include Claude Code illimitato, ma **non** fornisce una API key per `api.anthropic.com`. Questo proxy colma il gap: qualsiasi client che supporta l'API Anthropic (LiteLLM, Open Interpreter, script custom, ecc.) può puntare al proxy locale e sfruttare la subscription MAX.

## Architettura

```
Client (qualsiasi)
    │
    ▼
POST http://localhost:8082/v1/messages
    │  (Anthropic Messages API format)
    ▼
┌─────────────────────────┐
│   claude_proxy/server.py │
│   (FastAPI + uvicorn)    │
│                          │
│  1. Riceve request       │
│  2. Converte messages    │
│     in prompt testuale   │
│  3. Chiama claude -p     │
│  4. Parsa risposta       │
│  5. Ritorna in formato   │
│     Anthropic API        │
└─────────────────────────┘
    │
    ▼
claude -p --tools "" --output-format json --model <model>
    │  (headless invocation, no tools, no agent behavior)
    ▼
Anthropic API (autenticazione gestita da Claude Code)
```

## Funzionalità implementate (PoC Python)

### Endpoint `POST /v1/messages`
- Accetta request body nel formato standard Anthropic Messages API
- Supporta `system`, `messages`, `tools`, `max_tokens`, `model`, `stream`
- Mapping automatico dei model name (`*sonnet*` → `--model sonnet`, `*opus*` → `--model opus`, ecc.)

### Conversione messaggi
- Singolo messaggio user → passato direttamente come prompt
- Multi-turn → formattato come transcript `Human: ... / Assistant: ...`
- Content blocks (text, tool_use, tool_result) gestiti

### Streaming SSE
- Quando `stream: true`, la risposta viene emessa come Server-Sent Events
- Formato compatibile con il protocollo Anthropic: `message_start` → `content_block_start` → `content_block_delta` → `content_block_stop` → `message_delta` → `message_stop`
- Il proxy chiama `claude -p` in modo sincrono e poi simula lo streaming spezzando la risposta in chunks

### Tool use (sperimentale)
- Le definizioni dei tool vengono iniettate nel system prompt
- Il proxy cerca blocchi ` ```tool_use ``` ` nella risposta e li converte in content block `tool_use` nativi
- Funziona per casi semplici, non testato a fondo

### Dettagli tecnici
- Variabile `CLAUDECODE` rimossa dall'environment del subprocess per evitare il blocco "nested session"
- Prompt passato via stdin per evitare problemi di escaping shell
- `--tools ""` disabilita tutti i tool di Claude Code (Bash, Edit, Read, ecc.) così Claude risponde come puro chat model
- `--system-prompt` per passare il system prompt del client

## Test effettuati

### Test diretto con curl (funzionante)
```bash
curl -X POST http://localhost:8082/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: dummy" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 256,
    "messages": [{"role":"user","content":"Rispondi solo: ciao mondo"}]
  }'
```

Risposta:
```json
{
  "id": "msg_proxy_9fb7a4e6382749faaa150e31",
  "type": "message",
  "role": "assistant",
  "content": [{"type": "text", "text": "ciao mondo"}],
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {"input_tokens": 3, "output_tokens": 6}
}
```

### Test con Open Interpreter (streaming funzionante)
```bash
ANTHROPIC_API_BASE=http://localhost:8082 \
ANTHROPIC_API_KEY=dummy \
interpreter -y --model claude-3-5-sonnet-20241022
```
Open Interpreter si connette e interagisce correttamente via proxy.

## Limitazioni del PoC Python

- **Latenza**: ~2-3s di overhead per ogni invocazione (startup processo `claude`)
- **No streaming reale**: la risposta arriva tutta insieme da `claude -p`, lo streaming SSE è simulato
- **Stateless**: ogni request è indipendente, nessuna sessione persistente
- **Tool use fragile**: basato su parsing testuale di code blocks, non su tool_use nativo
- **Single request**: non gestisce richieste concorrenti in modo efficiente (ogni request spawna un processo)

## Prossimi passi → App nativa macOS (Swift)

L'obiettivo è riscrivere il proxy come **app macOS nativa in Swift** per:
- Performance migliore (no overhead Python/uvicorn)
- Gestione nativa dei processi e delle connessioni
- UI minimale nella menu bar per monitoraggio
- Supporto streaming reale tramite async/await Swift
- Distribuzione come .app standalone

## Uso rapido

```bash
# Avvia il proxy (da terminale NON dentro Claude Code)
python3 claude_proxy/server.py --port 8082

# Da qualsiasi client:
# - ANTHROPIC_API_BASE=http://localhost:8082
# - ANTHROPIC_API_KEY=dummy  (qualsiasi valore, ignorato dal proxy)
```

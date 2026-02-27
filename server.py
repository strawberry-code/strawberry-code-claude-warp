#!/usr/bin/env python3
"""
Claude Code → Anthropic Messages API Proxy

Espone un endpoint /v1/messages compatibile con l'API Anthropic,
usando internamente `claude -p` (headless) come backend.
Permette di usare la subscription MAX con tool come Open Interpreter.
"""

import asyncio
import json
import os
import subprocess
import uuid
import time
import argparse
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.responses import StreamingResponse
import uvicorn

app = FastAPI(title="Claude Code API Proxy")

# Mapping model names → claude CLI --model flag
MODEL_MAP = {
    "opus": "opus",
    "sonnet": "sonnet",
    "haiku": "haiku",
}


def resolve_model_flag(model_name: str) -> str:
    """Mappa il model name della request al flag --model di claude CLI."""
    model_lower = model_name.lower()
    for key, flag in MODEL_MAP.items():
        if key in model_lower:
            return flag
    # Default a sonnet se non riconosciuto
    return "sonnet"


def format_messages_as_prompt(messages: list) -> str:
    """Converte l'array messages Anthropic in un prompt testuale per claude -p."""
    if not messages:
        return ""

    # Caso singolo messaggio user: usa direttamente
    if len(messages) == 1 and messages[0]["role"] == "user":
        content = messages[0]["content"]
        if isinstance(content, str):
            return content
        # Content può essere array di content blocks
        if isinstance(content, list):
            return "\n".join(
                block["text"] for block in content
                if isinstance(block, dict) and block.get("type") == "text"
            )
        return str(content)

    # Multi-turn: formatta come transcript
    parts = []
    for msg in messages:
        role = msg["role"]
        content = msg["content"]

        # Normalizza content a stringa
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict):
                    if block.get("type") == "text":
                        text_parts.append(block["text"])
                    elif block.get("type") == "tool_result":
                        text_parts.append(f"[Tool result: {json.dumps(block.get('content', ''))}]")
                    elif block.get("type") == "tool_use":
                        text_parts.append(f"[Tool call: {block.get('name', '?')}({json.dumps(block.get('input', {}))})]")
                else:
                    text_parts.append(str(block))
            content = "\n".join(text_parts)

        if role == "user":
            parts.append(f"Human: {content}")
        elif role == "assistant":
            parts.append(f"Assistant: {content}")

    return "\n\n".join(parts)


def build_system_prompt(system: str | list | None, tools: list | None) -> str | None:
    """Costruisce il system prompt, aggiungendo tool definitions se presenti."""
    # Normalizza system prompt
    if system is None:
        sys_text = ""
    elif isinstance(system, str):
        sys_text = system
    elif isinstance(system, list):
        sys_text = "\n".join(
            block["text"] for block in system
            if isinstance(block, dict) and block.get("type") == "text"
        )
    else:
        sys_text = str(system)

    # Se ci sono tool definitions, aggiungile al system prompt
    if tools:
        tool_descriptions = []
        for tool in tools:
            name = tool.get("name", "unknown")
            desc = tool.get("description", "")
            schema = json.dumps(tool.get("input_schema", {}), indent=2)
            tool_descriptions.append(f"- **{name}**: {desc}\n  Input schema: {schema}")

        tools_section = (
            "\n\n---\n"
            "You have access to the following tools. To use a tool, respond with a JSON block like this:\n"
            '```tool_use\n{"name": "tool_name", "input": {...}}\n```\n\n'
            "Available tools:\n" + "\n".join(tool_descriptions)
        )
        sys_text += tools_section

    return sys_text if sys_text else None


def parse_tool_use_from_text(text: str) -> list:
    """Cerca blocchi tool_use nella risposta testuale e li parsa."""
    content_blocks = []
    remaining = text

    while "```tool_use" in remaining:
        before, _, after = remaining.partition("```tool_use")
        # Aggiungi testo prima del tool_use
        before_text = before.strip()
        if before_text:
            content_blocks.append({"type": "text", "text": before_text})

        # Estrai il JSON del tool_use
        json_str, _, remaining = after.partition("```")
        json_str = json_str.strip()
        try:
            tool_data = json.loads(json_str)
            content_blocks.append({
                "type": "tool_use",
                "id": f"toolu_{uuid.uuid4().hex[:24]}",
                "name": tool_data.get("name", "unknown"),
                "input": tool_data.get("input", {}),
            })
        except json.JSONDecodeError:
            # Se non è JSON valido, trattalo come testo
            content_blocks.append({"type": "text", "text": f"```tool_use\n{json_str}\n```"})

    # Testo rimanente dopo l'ultimo tool_use
    remaining_text = remaining.strip()
    if remaining_text:
        content_blocks.append({"type": "text", "text": remaining_text})

    # Se non c'erano tool_use, ritorna il testo originale
    if not content_blocks:
        content_blocks.append({"type": "text", "text": text})

    return content_blocks


async def call_claude_cli(prompt: str, system_prompt: str | None, model_flag: str) -> dict:
    """Chiama claude -p in modo asincrono e ritorna il risultato parsed."""
    cmd = [
        "claude", "-p",
        "--tools", "",
        "--output-format", "json",
        "--model", model_flag,
    ]

    if system_prompt:
        cmd.extend(["--system-prompt", system_prompt])

    # Rimuovi CLAUDECODE env var per evitare il blocco "nested session"
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

    # Passa il prompt via stdin per evitare problemi con escaping
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )

    stdout, stderr = await process.communicate(input=prompt.encode("utf-8"))

    if process.returncode != 0:
        error_msg = stderr.decode("utf-8", errors="replace")
        return {
            "type": "result",
            "subtype": "error",
            "is_error": True,
            "result": f"Claude CLI error: {error_msg}",
            "usage": {"input_tokens": 0, "output_tokens": 0},
        }

    try:
        return json.loads(stdout.decode("utf-8"))
    except json.JSONDecodeError:
        return {
            "type": "result",
            "subtype": "error",
            "is_error": True,
            "result": f"Invalid JSON from claude CLI: {stdout.decode('utf-8', errors='replace')[:500]}",
            "usage": {"input_tokens": 0, "output_tokens": 0},
        }


@app.post("/v1/messages")
async def messages_endpoint(request: Request):
    """Endpoint compatibile con Anthropic Messages API."""
    body = await request.json()

    # Estrai parametri dalla request
    model_name = body.get("model", "claude-sonnet-4-20250514")
    system = body.get("system")
    messages = body.get("messages", [])
    tools = body.get("tools")
    max_tokens = body.get("max_tokens", 4096)
    stream = body.get("stream", False)

    # Prepara prompt e system prompt
    prompt = format_messages_as_prompt(messages)
    system_prompt = build_system_prompt(system, tools)
    model_flag = resolve_model_flag(model_name)

    print(f"[proxy] model={model_name} → --model {model_flag} | messages={len(messages)} | tools={len(tools) if tools else 0} | stream={stream}")

    # Chiama claude CLI (sempre non-streaming, poi convertiamo)
    start = time.time()
    result = await call_claude_cli(prompt, system_prompt, model_flag)
    elapsed = time.time() - start

    print(f"[proxy] claude responded in {elapsed:.1f}s | error={result.get('is_error', False)}")

    # Gestisci errore
    if result.get("is_error"):
        error_body = {"type": "error", "error": {"type": "api_error", "message": result.get("result", "Unknown error")}}
        if stream:
            async def error_stream():
                yield f"event: error\ndata: {json.dumps(error_body)}\n\n"
            return StreamingResponse(error_stream(), media_type="text/event-stream")
        return JSONResponse(status_code=500, content=error_body)

    # Estrai risposta e usage
    response_text = result.get("result", "")
    usage = result.get("usage", {})

    # Parsa eventuali tool_use blocks dal testo
    has_tools = tools and len(tools) > 0
    if has_tools:
        content_blocks = parse_tool_use_from_text(response_text)
    else:
        content_blocks = [{"type": "text", "text": response_text}]

    # Determina stop_reason
    has_tool_use = any(b["type"] == "tool_use" for b in content_blocks)
    stop_reason = "tool_use" if has_tool_use else "end_turn"

    msg_id = f"msg_proxy_{uuid.uuid4().hex[:24]}"
    input_tokens = usage.get("input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)

    if stream:
        # Emetti la risposta come SSE Anthropic-compatibile
        async def sse_stream():
            # 1. message_start
            yield "event: message_start\ndata: " + json.dumps({
                "type": "message_start",
                "message": {
                    "id": msg_id,
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": model_name,
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": input_tokens, "output_tokens": 0},
                },
            }) + "\n\n"

            # 2. content blocks
            for idx, block in enumerate(content_blocks):
                if block["type"] == "text":
                    # content_block_start
                    yield "event: content_block_start\ndata: " + json.dumps({
                        "type": "content_block_start",
                        "index": idx,
                        "content_block": {"type": "text", "text": ""},
                    }) + "\n\n"

                    # content_block_delta — emetti il testo in chunks
                    text = block["text"]
                    chunk_size = 20  # ~20 chars per delta per simulare streaming
                    for i in range(0, len(text), chunk_size):
                        chunk = text[i:i + chunk_size]
                        yield "event: content_block_delta\ndata: " + json.dumps({
                            "type": "content_block_delta",
                            "index": idx,
                            "delta": {"type": "text_delta", "text": chunk},
                        }) + "\n\n"

                    # content_block_stop
                    yield "event: content_block_stop\ndata: " + json.dumps({
                        "type": "content_block_stop",
                        "index": idx,
                    }) + "\n\n"

                elif block["type"] == "tool_use":
                    # content_block_start per tool_use
                    yield "event: content_block_start\ndata: " + json.dumps({
                        "type": "content_block_start",
                        "index": idx,
                        "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}},
                    }) + "\n\n"

                    # input_json_delta
                    input_json = json.dumps(block["input"])
                    yield "event: content_block_delta\ndata: " + json.dumps({
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {"type": "input_json_delta", "partial_json": input_json},
                    }) + "\n\n"

                    # content_block_stop
                    yield "event: content_block_stop\ndata: " + json.dumps({
                        "type": "content_block_stop",
                        "index": idx,
                    }) + "\n\n"

            # 3. message_delta (stop_reason)
            yield "event: message_delta\ndata: " + json.dumps({
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": output_tokens},
            }) + "\n\n"

            # 4. message_stop
            yield "event: message_stop\ndata: " + json.dumps({
                "type": "message_stop",
            }) + "\n\n"

        return StreamingResponse(sse_stream(), media_type="text/event-stream")

    # Non-streaming: risposta JSON standard
    response = {
        "id": msg_id,
        "type": "message",
        "role": "assistant",
        "content": content_blocks,
        "model": model_name,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        },
    }

    return JSONResponse(content=response)


@app.get("/health")
async def health():
    return {"status": "ok", "backend": "claude-cli"}


def main():
    parser = argparse.ArgumentParser(description="Claude Code → Anthropic API Proxy")
    parser.add_argument("--port", type=int, default=8082, help="Porta del server (default: 8082)")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Host (default: 127.0.0.1)")
    args = parser.parse_args()

    print(f"🚀 Claude Code API Proxy avviato su http://{args.host}:{args.port}")
    print(f"   Configura Open Interpreter con:")
    print(f"   ANTHROPIC_API_BASE=http://{args.host}:{args.port}")
    print(f"   ANTHROPIC_API_KEY=dummy")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()

#!/bin/bash

curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder-7b",
    "messages": [
      {
        "role": "system",
        "content": "Tool Use Rules: Prefer calling a tool when the user asks for live or external data. If you call a tool, return ONLY the JSON call. After tool results are provided, summarize for the user."
      },
      { "role": "user", "content": "What is the weather in Boston right now?" }
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get current weather for a city",
          "parameters": {
            "type": "object",
            "properties": {
              "location": { "type": "string", "description": "City, State or City, Country" },
              "unit": { "type": "string", "enum": ["celsius", "fahrenheit"] }
            },
            "required": ["location"]
          }
        }
      }
    ],
    "tool_choice": "auto",
    "parallel_tool_calls": false
  }'


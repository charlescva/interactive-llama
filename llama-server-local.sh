cd ~/src/llama.cpp/build/bin

./llama-server \
  -m ~/Downloads/qwen2.5-coder-7b-instruct-q5_k_m.gguf \
  --alias qwen2.5-coder-7b \
  -ngl 29 \
  -c 4096 \
  -t 8 \
  --host 127.0.0.1 \
  --port 8080 \
  --jinja \
  --chat-template-file /home/pc2dev/Development/llama_interactive/agentic-chat-template.jinja
  # optionally: --api-key mylocalkey

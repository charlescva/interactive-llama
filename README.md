# interactive-llama

I made a qwen 2.5 7B Q5_K_M (GGUF) based reasoner/planner with tool enums to author files on the local filesystem within a given workspace.  
Tuned custom build of llama-cpp (w/o curl) to a GTX 1070 mobile w/ CUDA 6.1, it performs around 14 tokens/second.
This agent will accept a prompt and produce new Rust Project (w/ Cargo compatability), and attempt to include initial requirements.

#!/usr/bin/env python3
# gpt_oss_120b_server.py
#
# Launch GPT-OSS-120B as a Gradio chat server.
# Usage: python gpt_oss_120b_server.py
#
# Requirements:
#   pip install torch transformers accelerate bitsandbytes gradio xformers

import os
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
import gradio as gr

MODEL_ID = "openai/gpt-oss-120b"
HF_TOKEN = os.environ.get("HF_TOKEN")  # put your Hugging Face token here if required

print("Loading tokenizer...")
tokenizer = AutoTokenizer.from_pretrained(
    MODEL_ID,
    use_fast=True,
    trust_remote_code=True,
    token=HF_TOKEN
)

print("Loading model (this may take a while)...")
model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float16,
    device_map="auto",
    trust_remote_code=True,
    token=HF_TOKEN,
)
model.eval()
print("Model loaded.")

def generate(prompt: str, history=None, max_new_tokens: int = 256, temperature: float = 0.7, top_p: float = 0.9):
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    with torch.no_grad():
        output_ids = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            temperature=temperature,
            top_p=top_p,
            do_sample=True,
            eos_token_id=tokenizer.eos_token_id,
        )
    return tokenizer.decode(output_ids[0], skip_special_tokens=True)

with gr.Blocks(title="GPT-OSS-120B Chat") as demo:
    gr.Markdown("### 🤖 GPT‑OSS‑120B")
    gr.ChatInterface(
        fn=generate,
        chatbot=gr.Chatbot(height=400),
        textbox=gr.Textbox(placeholder="Ask me anything...", lines=2),
    )

demo.queue()
demo.launch(server_name="0.0.0.0", server_port=7860, share=False)

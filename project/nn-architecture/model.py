"""
GPT-2 model with Pre-LayerNorm (default).

Architecture matches GPT-2 small:
  - vocab_size = 50257
  - n_embd = 768
  - n_head = 12
  - n_layer = 12
  - n_positions = 1024
  - activation = SwiGLU (pre-LN)
  - Pre-LayerNorm enabled by default (use_pre_ln=True)
"""
from __future__ import annotations

import math
from typing import Optional

import torch
import torch.nn as nn
import torch.nn.functional as F


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

class GPT2Config:
    def __init__(
        self,
        vocab_size: int = 50257,
        n_positions: int = 1024,
        n_embd: int = 768,
        n_layer: int = 12,
        n_head: int = 12,
        n_inner: Optional[int] = None,
        activation_function: str = "gelu_new",
        layer_norm_epsilon: float = 1e-5,
        initializer_range: float = 0.02,
        use_qk_norm: bool = False,
        use_pre_ln: bool = True,
        use_rope: bool = False,
        use_swiglu: bool = True,
        use_parallel_block: bool = True,
        ln_init_random: bool = False,
        use_output_gate: bool = False,
        use_embed_norm: bool = True,
    ):
        self.vocab_size = vocab_size
        self.n_positions = n_positions
        self.n_embd = n_embd
        self.n_layer = n_layer
        self.n_head = n_head
        self.n_inner = n_inner if n_inner is not None else 4 * n_embd
        self.activation_function = activation_function
        self.layer_norm_epsilon = layer_norm_epsilon
        self.initializer_range = initializer_range
        self.use_qk_norm = use_qk_norm
        self.use_pre_ln = use_pre_ln
        self.use_rope = use_rope
        self.use_swiglu = use_swiglu
        self.use_parallel_block = use_parallel_block
        self.ln_init_random = ln_init_random
        self.use_output_gate = use_output_gate
        self.use_embed_norm = use_embed_norm

    @property
    def head_dim(self) -> int:
        assert self.n_embd % self.n_head == 0
        return self.n_embd // self.n_head


# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

class NewGELUActivation(nn.Module):
    """GELU approximation used in GPT-2 (also called 'gelu_new')."""
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return (
            0.5
            * x
            * (1.0 + torch.tanh(
                math.sqrt(2.0 / math.pi) * (x + 0.044715 * torch.pow(x, 3.0))
            ))
        )


class RotaryEmbedding(nn.Module):
    """Rotary Position Embeddings (RoPE), as used in LLaMA / GPT-NeoX.

    Precomputes cos/sin tables for the maximum sequence length and applies
    the rotation to query and key tensors in Attention.
    """
    def __init__(self, dim: int, max_position_embeddings: int = 1024, base: float = 10000.0):
        super().__init__()
        inv_freq = 1.0 / (base ** (torch.arange(0, dim, 2, dtype=torch.float32) / dim))
        self.register_buffer("inv_freq", inv_freq, persistent=False)

        # Precompute cos/sin cache
        t = torch.arange(max_position_embeddings, dtype=torch.float32)
        freqs = torch.outer(t, inv_freq)  # (T, dim/2)
        emb = torch.cat((freqs, freqs), dim=-1)  # (T, dim)
        self.register_buffer("cos_cached", emb.cos()[None, None, :, :], persistent=False)
        self.register_buffer("sin_cached", emb.sin()[None, None, :, :], persistent=False)

    def forward(self, q: torch.Tensor, k: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        """Apply rotary embeddings to q and k. Shapes: (B, nh, T, hd)."""
        cos = self.cos_cached[:, :, : q.size(2), :]
        sin = self.sin_cached[:, :, : q.size(2), :]
        # Apply half-rotate: (x1, x2) -> (x1 * cos - x2 * sin, x2 * cos + x1 * sin)
        # Neat trick from EleutherAI: rotate half the dims, treat pairs as (even, odd)
        half_dim = q.size(-1) // 2
        q1, q2 = q[..., :half_dim], q[..., half_dim:]
        k1, k2 = k[..., :half_dim], k[..., half_dim:]
        q_rotated = torch.cat((q1 * cos[..., :half_dim] - q2 * sin[..., :half_dim],
                               q2 * cos[..., :half_dim] + q1 * sin[..., :half_dim]), dim=-1)
        k_rotated = torch.cat((k1 * cos[..., :half_dim] - k2 * sin[..., :half_dim],
                               k2 * cos[..., :half_dim] + k1 * sin[..., :half_dim]), dim=-1)
        return q_rotated, k_rotated


class MLP(nn.Module):
    def __init__(self, config: GPT2Config):
        super().__init__()
        self.use_swiglu = config.use_swiglu
        self.log_activations = False  # set by parent model
        if config.use_swiglu:
            # SwiGLU: uses 8/3 * n_embd hidden dim (standard practice)
            n_inner = int(8/3 * config.n_embd)
            self.c_fc1 = nn.Linear(config.n_embd, n_inner, bias=True)
            self.c_fc2 = nn.Linear(config.n_embd, n_inner, bias=True)
            self.c_proj = nn.Linear(n_inner, config.n_embd, bias=True)
        else:
            self.c_fc = nn.Linear(config.n_embd, config.n_inner, bias=True)
            self.act = NewGELUActivation()
            self.c_proj = nn.Linear(config.n_inner, config.n_embd, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.use_swiglu:
            gate_out = F.silu(self.c_fc1(x))
            value_out = self.c_fc2(x)
            gated = gate_out * value_out
            out = self.c_proj(gated)
            if self.log_activations and not self.training:
                with torch.no_grad():
                    print(f"  MLP SwiGLU | gate: mean={gate_out.mean().item():.4f} std={gate_out.std().item():.4f} "
                          f"min={gate_out.min().item():.4f} max={gate_out.max().item():.4f} | "
                          f"value: mean={value_out.mean().item():.4f} std={value_out.std().item():.4f} | "
                          f"proj: mean={out.mean().item():.4f} std={out.std().item():.4f}")
            return out
        else:
            act_out = self.act(self.c_fc(x))
            out = self.c_proj(act_out)
            if self.log_activations and not self.training:
                with torch.no_grad():
                    print(f"  MLP GELU | act: mean={act_out.mean().item():.4f} std={act_out.std().item():.4f} "
                          f"min={act_out.min().item():.4f} max={act_out.max().item():.4f} | "
                          f"proj: mean={out.mean().item():.4f} std={out.std().item():.4f}")
            return out


class Attention(nn.Module):
    def __init__(self, config: GPT2Config):
        super().__init__()
        self.n_head = config.n_head
        self.head_dim = config.head_dim
        self.embed_dim = config.n_embd
        self.use_qk_norm = config.use_qk_norm
        self.use_rope = config.use_rope

        self.c_attn = nn.Linear(config.n_embd, 3 * config.n_embd, bias=True)
        self.c_proj = nn.Linear(config.n_embd, config.n_embd, bias=True)

        if self.use_qk_norm:
            self.q_norm = nn.LayerNorm(self.head_dim, eps=config.layer_norm_epsilon)
            self.k_norm = nn.LayerNorm(self.head_dim, eps=config.layer_norm_epsilon)

        # Learnable attention temperature (D5): tau > 0 via softplus
        self.tau = nn.Parameter(torch.ones(1))

        if self.use_rope:
            self.rotary = RotaryEmbedding(
                dim=self.head_dim,
                max_position_embeddings=config.n_positions,
            )

        self.register_buffer(
            "bias",
            torch.tril(torch.ones(config.n_positions, config.n_positions)).view(
                1, 1, config.n_positions, config.n_positions
            ),
        )

    def forward(
        self,
        x: torch.Tensor,
        attention_mask: Optional[torch.Tensor] = None,
    ) -> torch.Tensor:
        B, T, C = x.shape

        qkv = self.c_attn(x)  # (B, T, 3*C)
        q, k, v = qkv.chunk(3, dim=-1)

        q = q.view(B, T, self.n_head, self.head_dim).transpose(1, 2)  # (B, nh, T, hd)
        k = k.view(B, T, self.n_head, self.head_dim).transpose(1, 2)
        v = v.view(B, T, self.n_head, self.head_dim).transpose(1, 2)

        if self.use_qk_norm:
            # QK-Norm: apply LayerNorm on the head dimension
            q = self.q_norm(q)
            k = self.k_norm(k)

        if self.use_rope:
            q, k = self.rotary(q, k)

        attn_weights = (q @ k.transpose(-2, -1)) / (math.sqrt(self.head_dim) * F.softplus(self.tau))

        # Causal mask
        attn_weights = attn_weights + self.bias[:, :, :T, :T].float().masked_fill(
            self.bias[:, :, :T, :T] == 0, float("-inf")
        )

        if attention_mask is not None:
            attn_weights = attn_weights + attention_mask

        attn_weights = F.softmax(attn_weights, dim=-1)

        # Diagnostic: log softmax entropy per head (logged only during eval)
        if getattr(self, 'log_entropy', False) and not self.training:
            with torch.no_grad():
                # entropy = -sum(p * log(p)) along last dim
                ent = -(attn_weights * torch.log(attn_weights.clamp(min=1e-10))).sum(dim=-1)
                ent_mean = ent.mean().item()
                ent_min = ent.min().item()
                ent_max = ent.max().item()
                print(f"  Attn entropy | mean={ent_mean:.4f} min={ent_min:.4f} max={ent_max:.4f}")

        attn_output = attn_weights @ v  # (B, nh, T, hd)
        attn_output = attn_output.transpose(1, 2).contiguous().view(B, T, C)
        attn_output = self.c_proj(attn_output)
        return attn_output


class TransformerBlock(nn.Module):
    def __init__(self, config: GPT2Config, layer_idx: int = 0):
        super().__init__()
        self.use_pre_ln = config.use_pre_ln
        self.use_output_gate = config.use_output_gate
        self.ln_1 = nn.LayerNorm(config.n_embd, eps=config.layer_norm_epsilon)
        self.attn = Attention(config)
        self.ln_2 = nn.LayerNorm(config.n_embd, eps=config.layer_norm_epsilon)
        self.mlp = MLP(config)
        if config.use_output_gate:
            self.gate_attn = nn.Parameter(torch.ones(1))
            self.gate_mlp = nn.Parameter(torch.ones(1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.use_pre_ln:
            # Pre-LN: normalize before sublayer, residual connection bypasses norm
            if self.use_output_gate:
                gate_a = 1 + torch.tanh(self.gate_attn)
                gate_m = 1 + torch.tanh(self.gate_mlp)
                x = x + gate_a * self.attn(self.ln_1(x))
                x = x + gate_m * self.mlp(self.ln_2(x))
            else:
                x = x + self.attn(self.ln_1(x))
                x = x + self.mlp(self.ln_2(x))
        else:
            # Post-LN (GPT-2 default): normalize after adding residual
            if self.use_output_gate:
                gate_a = 1 + torch.tanh(self.gate_attn)
                gate_m = 1 + torch.tanh(self.gate_mlp)
                x = self.ln_1(x + gate_a * self.attn(x))
                x = self.ln_2(x + gate_m * self.mlp(x))
            else:
                x = self.ln_1(x + self.attn(x))
                x = self.ln_2(x + self.mlp(x))
        return x


class ParallelTransformerBlock(nn.Module):
    """PaLM-style parallel transformer block with shared Pre-LN and variance scaling.

    Computes attention and MLP outputs in parallel on the same normalized input,
    then sums both residuals scaled by 1/sqrt(2) to preserve variance.
    This halves the sequential depth and uses a single shared LayerNorm.
    """
    def __init__(self, config: GPT2Config):
        super().__init__()
        self.config = config
        self.use_output_gate = config.use_output_gate
        self.ln_1 = nn.LayerNorm(config.n_embd, eps=config.layer_norm_epsilon)
        self.attn = Attention(config)
        self.mlp = MLP(config)
        if config.use_output_gate:
            self.gate = nn.Parameter(torch.full((1,), -1.0))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Diagnostic: track input variance when enabled
        if getattr(self, 'log_activations', False) and not self.training:
            with torch.no_grad():
                x_var = x.var().item()
                x_mean = x.mean().item()

        # Shared norm: both branches see the same normalized input
        x_normed = self.ln_1(x)
        attn_out = self.attn(x_normed)
        mlp_out = self.mlp(x_normed)
        if self.use_output_gate:
            gate_val = 1 + torch.tanh(self.gate)
            out = x + gate_val * (attn_out + mlp_out) / math.sqrt(2)
        else:
            # Variance scaling: two independent residuals added → scale by 1/sqrt(2)
            out = x + (attn_out + mlp_out) / math.sqrt(2)

        if getattr(self, 'log_activations', False) and not self.training:
            with torch.no_grad():
                out_var = out.var().item()
                print(f"  ParallelBlock | input: mean={x_mean:.4f} var={x_var:.4f} "
                      f"output: mean={out.mean().item():.4f} var={out_var:.4f}")
        return out


class GPT2Model(nn.Module):
    def __init__(self, config: GPT2Config):
        super().__init__()
        self.config = config
        self.log_activations = False
        self.log_grad_norms = False

        self.wte = nn.Embedding(config.vocab_size, config.n_embd)
        self.wpe = nn.Embedding(config.n_positions, config.n_embd)
        self.drop = nn.Dropout(0.1)

        if config.use_embed_norm:
            self.ln_embed = nn.LayerNorm(config.n_embd, eps=config.layer_norm_epsilon)

        BlockCls = ParallelTransformerBlock if config.use_parallel_block else TransformerBlock
        self.h = nn.ModuleList(
            [BlockCls(config) for i in range(config.n_layer)]
        )
        # Propagate diagnostic flags to all blocks
        for block in self.h:
            block.log_activations = False  # will be set externally
            block.mlp.log_activations = False
            block.use_output_gate = config.use_output_gate
            if hasattr(block, 'attn'):
                block.attn.log_entropy = False

        # Linear gate offset across layers to break symmetry (D1 cold-start fix)
        n_layer = config.n_layer
        for i, block in enumerate(self.h):
            if hasattr(block, 'gate') and block.gate is not None:
                offset = 0.5 * (n_layer - 1 - i) / (n_layer - 1)
                block.gate.data = block.gate.data + offset

        self.ln_f = nn.LayerNorm(config.n_embd, eps=config.layer_norm_epsilon)

        # LM head (weights tied with wte)
        self.lm_head = nn.Linear(config.n_embd, config.vocab_size, bias=False)
        self.lm_head.weight = self.wte.weight  # weight tying

        self.apply(self._init_weights)

        # Apply special scaled init to residual projections
        for name, p in self.named_parameters():
            if name.endswith("c_proj.weight"):
                nn.init.normal_(p, mean=0.0, std=config.initializer_range / math.sqrt(config.n_layer))

    def _init_weights(self, module: nn.Module):
        if isinstance(module, nn.Linear):
            nn.init.normal_(module.weight, mean=0.0, std=self.config.initializer_range)
            if module.bias is not None:
                nn.init.zeros_(module.bias)
        elif isinstance(module, nn.Embedding):
            nn.init.normal_(module.weight, mean=0.0, std=self.config.initializer_range)
        elif isinstance(module, nn.LayerNorm):
            if module.bias is not None:
                nn.init.zeros_(module.bias)
            if module.weight is not None:
                if self.config.ln_init_random:
                    # Small random perturbation around 1.0 to break symmetry
                    # and improve gradient flow in Post-LN architectures.
                    nn.init.normal_(module.weight, mean=1.0, std=0.02)
                else:
                    nn.init.ones_(module.weight)

    def forward(
        self,
        input_ids: torch.LongTensor,
        attention_mask: Optional[torch.Tensor] = None,
        labels: Optional[torch.LongTensor] = None,
    ) -> dict[str, torch.Tensor]:
        B, T = input_ids.shape
        assert T <= self.config.n_positions, (
            f"Sequence length {T} exceeds max position {self.config.n_positions}"
        )

        # Token + optional position embeddings
        pos = torch.arange(0, T, device=input_ids.device).unsqueeze(0)
        tok_emb = self.wte(input_ids)
        if self.config.use_rope:
            # RoPE handles position information in attention; no learned position embeddings
            x = tok_emb
        else:
            pos_emb = self.wpe(pos)
            x = tok_emb + pos_emb

        if self.config.use_embed_norm:
            x = self.ln_embed(x)

        x = self.drop(x)

        for block in self.h:
            x = block(x)

        x = self.ln_f(x)
        logits = self.lm_head(x)

        loss = None
        if labels is not None:
            shift_logits = logits[..., :-1, :].contiguous()
            shift_labels = labels[..., 1:].contiguous()
            loss = F.cross_entropy(
                shift_logits.view(-1, shift_logits.size(-1)),
                shift_labels.view(-1),
                label_smoothing=0.1,
            )

        return {"loss": loss, "logits": logits}


def create_model(config: GPT2Config) -> GPT2Model:
    return GPT2Model(config)


# ---------------------------------------------------------------------------
# Diagnostics: Residual Variance Gate logging
# ---------------------------------------------------------------------------

@torch.no_grad()
def log_gate_values(model: GPT2Model, step: int, log_interval: int = 10):
    """Log the current values of residual output gates every `log_interval` steps."""
    if step % log_interval == 0 and model.config.use_output_gate:
        print(f"[Step {step}] Gate values:")
        for i, block in enumerate(model.h):
            if hasattr(block, 'gate'):
                gv = 1 + torch.tanh(block.gate)
                print(f"  Layer {i}: gate={gv.item():.4f}")
            elif hasattr(block, 'gate_attn'):
                ga = 1 + torch.tanh(block.gate_attn)
                gm = 1 + torch.tanh(block.gate_mlp)
                print(f"  Layer {i}: gate_attn={ga.item():.4f} gate_mlp={gm.item():.4f}")

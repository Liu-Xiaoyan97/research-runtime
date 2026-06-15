#!/usr/bin/env python3
"""GPT-2 training script for AutoResearch experiments.

All training is step-based (not epoch-based).
Default: 50 training steps, then final evaluation.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent))

from data import create_dataloaders  # noqa: E402
from model import GPT2Config, GPT2Model  # noqa: E402


def get_lr(it: int, warmup_iters: int, max_iters: int, max_lr: float, min_lr: float) -> float:
    if it < warmup_iters:
        return max_lr * (it + 1) / warmup_iters
    if it > max_iters:
        return min_lr
    decay_ratio = (it - warmup_iters) / (max_iters - warmup_iters)
    coeff = 0.5 * (1.0 + torch.cos(torch.tensor(decay_ratio * 3.14159)))
    return min_lr + coeff * (max_lr - min_lr)


@torch.no_grad()
def evaluate(model: nn.Module, val_loader: DataLoader, device: torch.device) -> float:
    model.eval()
    total_loss = 0.0
    n_batches = 0
    for batch in val_loader:
        input_ids = batch["input_ids"].to(device)
        labels = batch["labels"].to(device)
        outputs = model(input_ids=input_ids, labels=labels)
        total_loss += outputs["loss"].item()
        n_batches += 1
    model.train()
    return total_loss / n_batches


def main() -> int:
    parser = argparse.ArgumentParser(description="GPT-2 AutoResearch trainer")
    parser.add_argument("--exp-name", default="exp_0000_baseline")
    parser.add_argument("--model", default="gpt2")
    parser.add_argument("--dataset", default="wikitext")
    parser.add_argument("--dataset-config", default="wikitext-2-v1")
    parser.add_argument("--output-dir", default="output")
    parser.add_argument("--metrics-file", default=None)
    # Architecture flags
    parser.add_argument("--use-pre-ln", action="store_true")
    parser.add_argument("--use-qk-norm", action="store_true")
    parser.add_argument("--use-rope", action="store_true")
    parser.add_argument("--use-swiglu", action="store_true")
    parser.add_argument("--use-parallel-block", action="store_true")
    parser.add_argument("--ln-init-random", action="store_true",
                        help="Initialize LayerNorm weight with small random noise (mean=1.0, std=0.02)")
    parser.add_argument("--use-output-gate", action="store_true",
                        help="Enable learnable residual output gating (FINAL-001)")
    parser.add_argument("--use-embed-norm", action="store_true",
                        help="Enable embedding LayerNorm stabilization after embedding sum and before dropout")
    # Diagnostic flags
    parser.add_argument("--log-activations", action="store_true",
                        help="Log activation statistics for MLP layers")
    parser.add_argument("--log-grad-norms", action="store_true",
                        help="Log gradient L2 norms during training")
    # Training hyperparams
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--block-size", type=int, default=256)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--min-lr", type=float, default=1e-5)
    parser.add_argument("--warmup-steps", type=int, default=10)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--log-every", type=int, default=10)
    parser.add_argument("--train-steps", type=int, default=50,
                        help="Number of training steps (default: 50)")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    metrics_file = None
    if args.metrics_file:
        metrics_file = Path(args.metrics_file)
        metrics_file.parent.mkdir(parents=True, exist_ok=True)

    if torch.cuda.is_available():
        device = torch.device("cuda")
    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        device = torch.device("mps")
        print("Using MPS (Metal Performance Shaders) GPU acceleration")
    else:
        device = torch.device("cpu")
    print(f"Device: {device} | Steps: {args.train_steps}")

    torch.manual_seed(args.seed)

    print("Loading data...")
    train_loader, val_loader = create_dataloaders(
        batch_size=args.batch_size,
        block_size=args.block_size,
    )

    config = GPT2Config(
        vocab_size=50257,
        n_positions=args.block_size,
        use_pre_ln=args.use_pre_ln,
        use_qk_norm=args.use_qk_norm,
        use_rope=args.use_rope,
        use_swiglu=args.use_swiglu,
        use_parallel_block=args.use_parallel_block,
        ln_init_random=args.ln_init_random,
        use_output_gate=args.use_output_gate,
        use_embed_norm=args.use_embed_norm,
    )
    model = GPT2Model(config).to(device)
    total_params = sum(p.numel() for p in model.parameters())
    print(f"Params: {total_params:,}")

    # Enable diagnostic logging if requested
    if args.log_activations:
        model.log_activations = True
        for block in model.h:
            block.log_activations = True
            block.mlp.log_activations = True
            if hasattr(block, 'attn'):
                block.attn.log_entropy = True
    if args.log_grad_norms:
        model.log_grad_norms = True

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, betas=(0.9, 0.95), weight_decay=0.1)

    train_iter = iter(train_loader)
    best_val_loss = float("inf")
    loss_curve = []
    val_curve = []
    start_time = time.time()

    model.train()
    for step in range(args.train_steps):
        # Get next batch (restart iterator if exhausted)
        try:
            batch = next(train_iter)
        except StopIteration:
            train_iter = iter(train_loader)
            batch = next(train_iter)

        # LR schedule
        lr = get_lr(step, args.warmup_steps, args.train_steps, args.lr, args.min_lr)
        for pg in optimizer.param_groups:
            pg["lr"] = lr

        # Forward / backward
        input_ids = batch["input_ids"].to(device)
        labels = batch["labels"].to(device)
        outputs = model(input_ids=input_ids, labels=labels)
        loss = outputs["loss"]

        optimizer.zero_grad()
        loss.backward()

        # Compute gradient norm (unconditional, used for both logging and adaptive clip)
        total_norm = 0.0
        for p in model.parameters():
            if p.grad is not None:
                param_norm = p.grad.data.norm(2)
                total_norm += param_norm.item() ** 2
        total_norm = total_norm ** 0.5

        if args.log_grad_norms:
            print(f"  Gradient norm (pre-clip): {total_norm:.4f}")

        # Adaptive gradient clipping (D6): EMA-based clip threshold
        if step == 0:
            grad_norm_ema = total_norm
        else:
            grad_norm_ema = 0.9 * grad_norm_ema + 0.1 * total_norm

        if step < args.warmup_steps:
            clip_val = 5.0
        else:
            clip_val = max(1.0, grad_norm_ema * 2.0)

        torch.nn.utils.clip_grad_norm_(model.parameters(), clip_val)
        optimizer.step()

        loss_curve.append({"step": step, "train_loss": loss.item()})

        if step % args.log_every == 0 or step == args.train_steps - 1:
            elapsed = time.time() - start_time
            print(f"step {step:>4d}/{args.train_steps} | loss {loss.item():.4f} | lr {lr:.2e} | {elapsed:.1f}s")

        # Log gate values if output gate is active
        if step % args.log_every == 0 and args.use_output_gate:
            from model import log_gate_values
            log_gate_values(model, step, log_interval=args.log_every)

    # Final evaluation
    print("Running final evaluation...")
    final_val_loss = evaluate(model, val_loader, device)
    best_val_loss = final_val_loss  # only one eval for 50-step runs
    best_epoch = args.train_steps
    val_curve.append({"step": args.train_steps, "val_loss": final_val_loss})
    print(f"Final val_loss: {final_val_loss:.4f}")

    # Save checkpoint
    torch.save(model.state_dict(), output_dir / "model.pt")

    # Metrics
    metrics = {
        "exp_name": args.exp_name,
        "model": args.model,
        "dataset": args.dataset,
        "dataset_config": args.dataset_config,
        "architecture": {
            "use_pre_ln": args.use_pre_ln,
            "use_qk_norm": args.use_qk_norm,
            "use_rope": args.use_rope,
            "use_swiglu": args.use_swiglu,
            "use_parallel_block": args.use_parallel_block,
            "ln_init_random": args.ln_init_random,
            "use_output_gate": args.use_output_gate,
            "use_embed_norm": args.use_embed_norm,
        },
        "total_params": total_params,
        "best_val_loss": best_val_loss,
        "final_val_loss": final_val_loss,
        "best_epoch": best_epoch,
        "total_steps": args.train_steps,
        "loss_curve": loss_curve,
        "val_curve": val_curve,
        "training_time_sec": time.time() - start_time,
    }
    print(json.dumps({k: v for k, v in metrics.items() if k != "loss_curve"}, indent=2))

    if metrics_file:
        metrics_file.write_text(
            json.dumps(metrics, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Data loading for WikiText-2 language modeling."""
from __future__ import annotations

import torch
from torch.utils.data import Dataset, DataLoader
from datasets import load_dataset
from tiktoken import get_encoding


def get_tokenizer():
    """Use GPT-2's BPE tokenizer via tiktoken."""
    return get_encoding("gpt2")


def encode(text: str, tokenizer, max_length: int) -> torch.LongTensor:
    tokens = tokenizer.encode(text)
    # Truncate to fit within context window
    tokens = tokens[:max_length]
    return torch.tensor(tokens, dtype=torch.long)


class WikitextDataset(Dataset):
    def __init__(self, split: str = "train", block_size: int = 256):
        self.block_size = block_size
        self.tokenizer = get_tokenizer()

        raw = load_dataset("wikitext", "wikitext-2-v1", split=split)
        text = "\n\n".join(raw["text"])
        ids = self.tokenizer.encode(text)
        # Chunk into fixed-length blocks
        self.examples = []
        for i in range(0, len(ids) - block_size, block_size):
            chunk = ids[i : i + block_size]
            self.examples.append(torch.tensor(chunk, dtype=torch.long))

    def __len__(self) -> int:
        return len(self.examples)

    def __getitem__(self, idx: int) -> dict[str, torch.Tensor]:
        x = self.examples[idx]
        y = x  # CLM: input and target are the same (shifted inside loss)
        return {"input_ids": x, "labels": y}


def create_dataloaders(
    batch_size: int = 8,
    block_size: int = 256,
    num_workers: int = 0,
) -> tuple[DataLoader, DataLoader]:
    train_ds = WikitextDataset("train", block_size=block_size)
    val_ds = WikitextDataset("validation", block_size=block_size)
    train_loader = DataLoader(
        train_ds, batch_size=batch_size, shuffle=True, num_workers=num_workers
    )
    val_loader = DataLoader(
        val_ds, batch_size=batch_size, shuffle=False, num_workers=num_workers
    )
    return train_loader, val_loader

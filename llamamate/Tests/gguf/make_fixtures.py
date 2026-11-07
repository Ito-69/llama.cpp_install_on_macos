#!/usr/bin/env python3
"""Writes small synthetic GGUF v3 headers used by the GGUFInfo parser test."""
import struct, sys, os

U8, I8, U16, I16, U32, I32, F32, BOOL, STR, ARR, U64, I64, F64 = range(13)

def s(x):
    b = x.encode()
    return struct.pack('<Q', len(b)) + b

def kv(key, t, val):
    out = s(key) + struct.pack('<I', t)
    if t == STR: out += s(val)
    elif t == U32: out += struct.pack('<I', val)
    elif t == I32: out += struct.pack('<i', val)
    elif t == F32: out += struct.pack('<f', val)
    elif t == BOOL: out += struct.pack('<B', 1 if val else 0)
    elif t == ARR:
        et, items = val
        out += struct.pack('<I', et) + struct.pack('<Q', len(items))
        for it in items:
            if et == STR: out += s(it)
            elif et == I32: out += struct.pack('<i', it)
            elif et == U32: out += struct.pack('<I', it)
            elif et == BOOL: out += struct.pack('<B', 1 if it else 0)
            elif et == F32: out += struct.pack('<f', it)
    return out

def tensor(name):
    return s(name) + struct.pack('<I', 2) + struct.pack('<QQ', 16, 16) + struct.pack('<I', 0) + struct.pack('<Q', 0)

def gguf(path, kvs, tensors):
    data = b'GGUF' + struct.pack('<I', 3) + struct.pack('<Q', len(tensors)) + struct.pack('<Q', len(kvs))
    data += b''.join(kvs) + b''.join(tensor(t) for t in tensors)
    with open(path, 'wb') as f:
        f.write(data)

def tokens(n):
    return kv('tokenizer.ggml.tokens', ARR, (STR, ['tok%d' % i for i in range(n)]))

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

# 1. Dense llama: 32 layers x 8 KV heads; large tokenizer array before arch keys.
gguf(f'{out}/dense.gguf', [
    kv('general.architecture', STR, 'llama'),
    tokens(5000),
    kv('tokenizer.ggml.scores', ARR, (F32, [0.0] * 5000)),
    kv('llama.block_count', U32, 32),
    kv('llama.attention.head_count_kv', U32, 8),
    kv('llama.attention.key_length', U32, 128),
    kv('llama.context_length', U32, 131072),
], ['blk.0.attn_q.weight', 'blk.0.attn_k.weight'])

# 2. Hybrid qwen35 with MTP: 64 main layers + 1 nextn, interval 4 -> 16 + 1 attention layers.
gguf(f'{out}/qwen35_mtp.gguf', [
    kv('general.architecture', STR, 'qwen35'),
    kv('qwen35.block_count', U32, 65),
    kv('qwen35.attention.head_count_kv', U32, 4),
    kv('qwen35.attention.key_length', U32, 256),
    kv('qwen35.full_attention_interval', U32, 4),
    kv('qwen35.nextn_predict_layers', U32, 1),
    kv('qwen35.context_length', U32, 262144),
    tokens(2000),
], ['blk.0.attn_qkv.weight', 'blk.63.attn_q.weight', 'blk.64.nextn.eh_proj.weight'])

# 3. Same arch, nextn key present but MTP tensors stripped; no interval key (default 4).
gguf(f'{out}/qwen35_nomtp.gguf', [
    kv('general.architecture', STR, 'qwen35'),
    kv('qwen35.block_count', U32, 65),
    kv('qwen35.attention.head_count_kv', U32, 4),
    kv('qwen35.attention.key_length', U32, 256),
    kv('qwen35.nextn_predict_layers', U32, 1),
], ['blk.0.attn_qkv.weight', 'blk.63.attn_q.weight'])

# 4. Per-layer head_count_kv array (0 = no attention), e.g. granite-hybrid style.
gguf(f'{out}/perlayer.gguf', [
    kv('general.architecture', STR, 'granitehybrid'),
    kv('granitehybrid.block_count', U32, 8),
    kv('granitehybrid.attention.head_count_kv', ARR, (I32, [0, 0, 8, 0, 0, 0, 8, 0])),
    kv('granitehybrid.embedding_length', U32, 4096),
    kv('granitehybrid.attention.head_count', U32, 32),
], ['blk.0.ssm_in.weight'])

# 5. recurrent_layers bool array + sliding window (approximate).
gguf(f'{out}/recurrent.gguf', [
    kv('general.architecture', STR, 'lfm2'),
    kv('lfm2.block_count', U32, 6),
    kv('lfm2.attention.head_count_kv', U32, 8),
    kv('lfm2.attention.key_length', U32, 64),
    kv('lfm2.attention.recurrent_layers', ARR, (BOOL, [1, 1, 0, 1, 0, 1])),
    kv('lfm2.attention.sliding_window', U32, 4096),
], ['blk.0.shortconv.weight'])

# 6. Not a GGUF file.
with open(f'{out}/notgguf.gguf', 'wb') as f:
    f.write(b'NOPE' + b'\0' * 64)

#!/usr/bin/env sh
set -e
if [ -f .env ]; then . .env; fi
export EMBED_MODEL="${EMBED_MODEL:-all-mpnet-base-v2}"
export DIM="${DIM:-768}"
export TOP_K="${TOP_K:-5}"
export FAISS_INDEX="${FAISS_INDEX:-./knowledge.index}"
export DOC_STORE="${DOC_STORE:-./docs.jsonl}"
export LLM_URL="${LLM_URL:-http://localhost:11434/api/generate}"
export LLM_MODEL="${LLM_MODEL:-llama3.2}"
export CACHE_TTL="${CACHE_TTL:-3600}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379/0}"
export RETRIEVAL_MODE="${RETRIEVAL_MODE:-hyde}"

check_deps() {
    for cmd in python3 curl jq bc; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Missing: $cmd" >&2; exit 1
        fi
    done
    python3 -c "import sentence_transformers, faiss, numpy" 2>/dev/null || {
        echo "Run: pip install -r requirements.txt" >&2; exit 1
    }
}

get_embedding() {
    python3 -c "
from sentence_transformers import SentenceTransformer
import json, sys
model = SentenceTransformer('$EMBED_MODEL')
vec = model.encode(sys.argv[1]).tolist()
print(json.dumps(vec))
" "$1"
}

generate_hypothetical() {
    query="$1"
    if [ -n "$REDIS_URL" ] && command -v redis-cli > /dev/null 2>&1; then
        cached=$(redis-cli --raw get "hyde:$query" 2>/dev/null || echo "")
        if [ -n "$cached" ]; then echo "$cached"; return; fi
    fi
    prompt="Write a comprehensive, factual passage answering: $query. Use formal tone. No filler."
    hyp_doc=$(curl -s "$LLM_URL" -d "{\"model\":\"$LLM_MODEL\",\"prompt\":\"$prompt\",\"stream\":false}" | jq -r '.response')
    if [ -n "$REDIS_URL" ] && command -v redis-cli > /dev/null 2>&1 && [ -n "$hyp_doc" ]; then
        redis-cli setex "hyde:$query" "$CACHE_TTL" "$hyp_doc" 2>/dev/null || true
    fi
    echo "$hyp_doc"
}

search_index() {
    if [ ! -f "$FAISS_INDEX" ]; then
        echo "Index not found. Run: $0 build" >&2; exit 1
    fi
    echo "$1" | python3 -c "
import sys, json, faiss, numpy as np
vec = np.array(json.loads(sys.stdin.read()), dtype=np.float32).reshape(1, -1)
index = faiss.read_index('$FAISS_INDEX')
D, I = index.search(vec, $TOP_K)
for idx, score in zip(I[0], D[0]):
    print(f'{idx}\t{score}')
"
}

retrieve() {
    query="$1"
    if [ "$RETRIEVAL_MODE" = "hyde" ]; then
        echo "🔄 HyDE mode..." >&2
        embed_input=$(generate_hypothetical "$query")
    else
        echo "⚡ Standard mode..." >&2
        embed_input="$query"
    fi
    echo "📐 Embedding..." >&2
    vec=$(get_embedding "$embed_input")
    echo "🔍 Searching..." >&2
    search_index "$vec"
}

build_index() {
    if [ ! -f "$DOC_STORE" ]; then
        echo "No $DOC_STORE. Create one from samples." >&2
        exit 1
    fi
    echo "🏗️ Building FAISS index..."
    cat "$DOC_STORE" | python3 -c "
import sys, json, faiss, numpy as np
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('$EMBED_MODEL')
docs = [json.loads(line) for line in sys.stdin]
texts = [d['text'] for d in docs]
embeddings = model.encode(texts, batch_size=32, show_progress_bar=True)
embeddings = np.array(embeddings).astype(np.float32)
dim = embeddings.shape[1]
nlist = min(100, len(docs))
if len(docs) < 5000:
    index = faiss.IndexFlatIP(dim)
else:
    quantizer = faiss.IndexFlatIP(dim)
    index = faiss.IndexIVFPQ(quantizer, dim, nlist, 8, 8)
    index.train(embeddings)
index.add(embeddings)
faiss.write_index(index, '$FAISS_INDEX')
with open('./doc_meta.json', 'w') as f:
    json.dump(docs, f)
print('✅ Index built.')
"
}

benchmark_mode() {
    mode="$1"
    test_file="${2:-./queries.tsv}"
    if [ ! -f "$test_file" ]; then echo "No $test_file"; exit 1; fi
    export RETRIEVAL_MODE="$mode"
    total_time=0; hits=0; total=0
    total=$(wc -l < "$test_file" | tr -d ' ')
    while IFS= read -r line; do
        query=$(echo "$line" | cut -f1)
        expected=$(echo "$line" | cut -f2)
        [ -z "$query" ] && continue
        start=$(date +%s%N)
        top_id=$(retrieve "$query" 2>/dev/null | head -1 | cut -f1)
        end=$(date +%s%N)
        duration=$(( (end - start) / 1000000 ))
        tot




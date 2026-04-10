#!/usr/bin/env bash
# ==========================================================================
# STAGE 3: Integrations — NotebookLM bridge, Vector DB, API Gateway
# Target: Raspberry Pi 5 (aarch64), after Stage 2 completion
# Version: 3.0.0
# Usage: sudo bash stage3_integrations.sh [--ruflo-repo=URL] [--dry-run] [--force]
# ==========================================================================
set -euo pipefail

# === 0. ARG PARSING ===
DRY_RUN="false"; FORCE="false"
RUFLO_REPO="${RUFLO_REPO:-}"  # e.g., https://github.com/xxx/ruflo.git

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ruflo-repo=*) RUFLO_REPO="${1#*=}"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        -h|--help) echo "Usage: $0 [--ruflo-repo=URL] [--dry-run] [--force]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# === 1. CONSTANTS ===
readonly VERSION="3.0.0"
readonly LOG_FILE="/var/log/rpi5_agent_stage3.log"
readonly AGENT_USER="${SUDO_USER:-$(logname || echo code)}"
readonly AGENT_HOME="/home/$AGENT_USER"
readonly AGENT_VENV="$AGENT_HOME/.venv/agents"
readonly AGENT_DIR="$AGENT_HOME/agent-stack"
readonly DATA_DIR="/data"
readonly NOTES_DIR="$DATA_DIR/notes"
readonly VECTOR_DIR="$DATA_DIR/vector_store"

# === 2. LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === 3. PRE-FLIGHT ===
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -d "$AGENT_VENV" ]] || die "Stage 2 not complete: venv missing"
[[ -d "$DATA_DIR" ]] || die "Stage 1 not complete: /data missing"

log "Stage 3 v$VERSION starting"
[[ "$DRY_RUN" == "true" ]] && log "🔍 DRY RUN: no changes"

# === 4. CREATE DIRECTORIES ===
log "Setting up data directories..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$NOTES_DIR" "$VECTOR_DIR" "$DATA_DIR/{config,workspace,backups}"
    chown -R "$AGENT_USER:$AGENT_USER" "$DATA_DIR"
    chmod -R 755 "$DATA_DIR"
    log "✅ Directories ready: notes, vector_store, config, workspace"
else
    log "[DRY] Would create directories"
fi

# === 5. NOTEBOOKLM BRIDGE: INDEXER ===
log "Creating NotebookLM bridge (indexer.py)..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$AGENT_DIR/indexer.py" <<'PYEOF'
#!/usr/bin/env python3
"""NotebookLM Bridge: Import sources → ChromaDB vector store"""
import os, sys, logging, hashlib
from pathlib import Path
from dotenv import load_dotenv
import chromadb
from chromadb.utils import embedding_functions

# Config
load_dotenv(Path(__file__).parent / ".env")
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
NOTES_DIR = DATA_DIR / "notes"
VECTOR_DIR = DATA_DIR / "vector_store"
COLLECTION_NAME = "agent_knowledge"

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("indexer")

def get_embedding_func():
    """Use local sentence-transformers (no API calls)"""
    return embedding_functions.SentenceTransformerEmbeddingFunction(
        model_name="all-MiniLM-L6-v2",  # lightweight, ~80MB
        device="cpu"  # Pi 5 CPU-only
    )

def load_text_file(filepath: Path) -> str:
    """Load text/markdown/md files"""
    try:
        return filepath.read_text(encoding="utf-8", errors="ignore")
    except Exception as e:
        logger.warning(f"Could not read {filepath}: {e}")
        return ""

def compute_hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:12]

def index_notes():
    """Main indexing function"""
    logger.info(f"📚 Indexing notes from {NOTES_DIR}")
    
    # Init ChromaDB (persistent, disk-backed)
    client = chromadb.PersistentClient(path=str(VECTOR_DIR))
    embed_func = get_embedding_func()
    
    # Get or create collection
    collection = client.get_or_create_collection(
        name=COLLECTION_NAME,
        embedding_function=embed_func,
        metadata={"hnsw:space": "cosine"}  # efficient for CPU
    )
    
    # Scan notes directory
    files_processed = 0
    for filepath in NOTES_DIR.rglob("*"):
        if filepath.suffix.lower() not in [".txt", ".md", ".markdown"]:
            continue
        if not filepath.is_file():
            continue
            
        content = load_text_file(filepath)
        if not content.strip():
            continue
            
        doc_id = f"{filepath.stem}_{compute_hash(content)}"
        
        # Check if already indexed
        existing = collection.get(ids=[doc_id])
        if existing["ids"]:
            logger.debug(f"⏭️  Already indexed: {filepath.name}")
            continue
        
        # Add to vector store (chunk if too long)
        max_len = 4000
        chunks = [content[i:i+max_len] for i in range(0, len(content), max_len)]
        
        for i, chunk in enumerate(chunks):
            collection.add(
                ids=[f"{doc_id}_chunk{i}"],
                documents=[chunk],
                metadatas=[{
                    "source": str(filepath.relative_to(NOTES_DIR)),
                    "chunk": i,
                    "total_chunks": len(chunks)
                }]
            )
        files_processed += 1
        logger.info(f"✅ Indexed: {filepath.name} ({len(chunks)} chunks)")
    
    logger.info(f"🎯 Indexing complete: {files_processed} files processed")
    return collection

if __name__ == "__main__":
    try:
        index_notes()
        logger.info("✨ NotebookLM bridge ready")
    except Exception as e:
        logger.error(f"Indexing failed: {e}", exc_info=True)
        sys.exit(1)
PYEOF
    chmod +x "$AGENT_DIR/indexer.py"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/indexer.py"
    log "✅ Created indexer.py (NotebookLM → ChromaDB)"
else
    log "[DRY] Would create indexer.py"
fi

# === 6. VECTOR QUERY HELPER ===
log "Creating vector query helper..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$AGENT_DIR/vector_query.py" <<'PYEOF'
#!/usr/bin/env python3
"""Vector Query Helper: Search context from ChromaDB"""
import os, logging
from pathlib import Path
from dotenv import load_dotenv
import chromadb
from chromadb.utils import embedding_functions

load_dotenv(Path(__file__).parent / ".env")
VECTOR_DIR = Path(os.getenv("VECTOR_DB_PATH", "/data/vector_store"))
COLLECTION_NAME = "agent_knowledge"

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("vector_query")

class VectorQuery:
    def __init__(self, collection_name: str = COLLECTION_NAME):
        self.client = chromadb.PersistentClient(path=str(VECTOR_DIR))
        embed_func = embedding_functions.SentenceTransformerEmbeddingFunction(
            model_name="all-MiniLM-L6-v2", device="cpu"
        )
        self.collection = self.client.get_collection(collection_name, embedding_function=embed_func)
    
    def search(self, query: str, n_results: int = 3) -> list[dict]:
        """Search for relevant context"""
        try:
            results = self.collection.query(
                query_texts=[query],
                n_results=min(n_results, 10)  # limit for CPU
            )
            return [
                {"text": doc, "source": meta.get("source"), "score": 1 - (dist or 0)}
                for doc, meta, dist in zip(
                    results["documents"][0],
                    results["metadatas"][0],
                    results["distances"][0] if results["distances"] else [0]*len(results["documents"][0])
                )
            ]
        except Exception as e:
            logger.error(f"Query failed: {e}")
            return []
    
    def format_context(self, results: list[dict], max_tokens: int = 2000) -> str:
        """Format results for LLM context window"""
        if not results:
            return "📭 No relevant context found."
        
        parts = []
        total_chars = 0
        for r in results:
            chunk = f"[{r['source']}] (relevance: {r['score']:.2f})\n{r['text']}\n---\n"
            if total_chars + len(chunk) > max_tokens * 4:  # rough token→char estimate
                break
            parts.append(chunk)
            total_chars += len(chunk)
        
        return "📚 Context from knowledge base:\n\n" + "\n".join(parts)

# CLI test
if __name__ == "__main__":
    import sys
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "test query"
    vq = VectorQuery()
    results = vq.search(query)
    print(vq.format_context(results))
PYEOF
    chmod +x "$AGENT_DIR/vector_query.py"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/vector_query.py"
    log "✅ Created vector_query.py"
else
    log "[DRY] Would create vector_query.py"
fi

# === 7. FASTAPI GATEWAY ===
log "Creating FastAPI gateway..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$AGENT_DIR/api.py" <<'PYEOF'
#!/usr/bin/env python3
"""FastAPI Gateway for Pi5 Agent Stack"""
import os, logging, asyncio
from pathlib import Path
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel

# Local imports
from vector_query import VectorQuery
from indexer import index_notes

load_dotenv(Path(__file__).parent / ".env")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("api")

# Global state
vector_db: VectorQuery | None = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global vector_db
    logger.info("🔌 API Gateway starting...")
    vector_db = VectorQuery()
    logger.info("✅ Vector DB connected")
    yield
    logger.info("🔌 API Gateway shutting down")

app = FastAPI(
    title="Pi5 Agent API",
    description="REST interface for Raspberry Pi 5 AI Agent Stack",
    version="1.0.0",
    lifespan=lifespan
)

class QueryRequest(BaseModel):
    query: str
    n_results: int = 3
    max_context_tokens: int = 2000

class AgentRequest(BaseModel):
    task: str
    use_context: bool = True
    model: str = "claude-sonnet-4-20250514"

@app.get("/health")
async def health():
    return {"status": "healthy", "vector_db": "connected" if vector_db else "disconnected"}

@app.post("/query")
async def query_kb(req: QueryRequest):
    if not vector_db:
        raise HTTPException(503, "Vector DB not ready")
    results = vector_db.search(req.query, n_results=req.n_results)
    context = vector_db.format_context(results, max_tokens=req.max_context_tokens)
    return {"query": req.query, "results_count": len(results), "context": context}

@app.post("/agent")
async def run_agent(req: AgentRequest, background: BackgroundTasks):
    """Placeholder: integrate Claude Code + agency-agents here"""
    logger.info(f"🤖 Agent task: {req.task[:100]}...")
    
    # Optional: enrich with vector context
    context = ""
    if req.use_context and vector_db:
        results = vector_db.search(req.task, n_results=2)
        context = vector_db.format_context(results, max_tokens=1000)
    
    # TODO: Call Claude Code API with context
    # For now, return mock response
    return {
        "task": req.task,
        "model": req.model,
        "context_used": bool(context),
        "status": "queued",  # async processing
        "note": "Integrate Claude Code CLI here"
    }

@app.post("/index")
async def trigger_indexing(background: BackgroundTasks):
    """Trigger background re-indexing of /data/notes"""
    background.add_task(lambda: asyncio.run(index_notes()))
    return {"status": "indexing_started", "notes_dir": str(Path(os.getenv("DATA_DIR", "/data")) / "notes")}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level=LOG_LEVEL.lower())
PYEOF
    chmod +x "$AGENT_DIR/api.py"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/api.py"
    log "✅ Created api.py (FastAPI gateway)"
else
    log "[DRY] Would create api.py"
fi

# === 8. RUFLO INTEGRATION (PLACEHOLDER) ===
if [[ -n "$RUFLO_REPO" ]]; then
    log "Integrating Ruflo from: $RUFLO_REPO"
    if [[ "$DRY_RUN" != "true" ]]; then
        RUFLO_DIR="$AGENT_DIR/ruflo"
        mkdir -p "$RUFLO_DIR"
        if git clone --depth 1 "$RUFLO_REPO" "$RUFLO_DIR" >/dev/null 2>&1; then
            log "✅ Cloned Ruflo"
            # TODO: Add Ruflo-specific setup here based on actual repo
        else
            warn "Could not clone Ruflo repo"
        fi
    fi
else
    log "⏭️  Ruflo integration skipped (use --ruflo-repo=URL to enable)"
fi

# === 9. UPDATE ORCHESTRATOR ===
log "Updating orchestrator with integrations..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Append integration hooks to orchestrator.py
    cat >> "$AGENT_DIR/orchestrator.py" <<'PYAPPEND'

# === INTEGRATION HOOKS (Stage 3) ===
from vector_query import VectorQuery
_vector_db = None

def get_vector_db():
    global _vector_db
    if _vector_db is None:
        _vector_db = VectorQuery()
    return _vector_db

async def process_with_context(task: str) -> str:
    """Example: enrich task with vector context before Claude call"""
    vdb = get_vector_db()
    results = vdb.search(task, n_results=2)
    context = vdb.format_context(results, max_tokens=1500)
    # TODO: Pass `context` to Claude Code prompt
    return f"[Context loaded]\n{task}"
PYAPPEND
    log "✅ Orchestrator updated with vector hooks"
else
    log "[DRY] Would update orchestrator"
fi

# === 10. SYSTEMD: API SERVICE ===
log "Creating API gateway service..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > /etc/systemd/system/pi5-agent-api.service <<SVC
[Unit]
Description=Pi5 Agent API Gateway
After=pi5-agent.service network.target
Wants=pi5-agent.service

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$AGENT_DIR
Environment=PATH=$AGENT_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=$AGENT_VENV/bin/python $AGENT_DIR/api.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    log "✅ Created pi5-agent-api.service"
else
    log "[DRY] Would create API service"
fi

# === 11. VALIDATION ===
log "=== VALIDATION ==="
if [[ "$DRY_RUN" != "true" ]]; then
    source "$AGENT_VENV/bin/activate" 2>/dev/null || true
    python -c "from vector_query import VectorQuery; print('✅ VectorQuery import OK')" 2>/dev/null && log "✅ vector_query.py: OK" || warn "❌ vector_query"
    python -c "import chromadb; print('✅ ChromaDB OK')" 2>/dev/null && log "✅ ChromaDB: OK" || warn "❌ ChromaDB"
    [[ -f "$AGENT_DIR/api.py" ]] && log "✅ api.py: present" || warn "❌ api.py missing"
    systemctl list-unit-files pi5-agent-api.service 2>/dev/null | grep -q enabled && log "✅ API service: configured" || warn "⏳ API service: not enabled"
fi

log "╔════════════════════════════════════════╗"
log "║  ✅ Stage 3 COMPLETE!                   ║"
log "║                                        ║"
log "║  📁 Components:                        ║"
log "║  • indexer.py    — NotebookLM bridge   ║"
log "║  • vector_query.py — Context search    ║"
log "║  • api.py        — FastAPI gateway     ║"
log "║  • orchestrator.py — Updated hooks     ║"
log "║                                        ║"
log "║  🚀 Next:                              ║"
log "║  1. Add sources to /data/notes/        ║"
log "║  2. Run: source ~/.venv/agents/bin/activate"
log "║  3. Index: python ~/agent-stack/indexer.py"
log "║  4. Start API: sudo systemctl start pi5-agent-api"
log "║  5. Test: curl http://localhost:8000/health"
log "║                                        ║"
log "║  🔗 Ruflo: use --ruflo-repo=URL to add ║"
log "╚════════════════════════════════════════╝"

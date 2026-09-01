"""AdaptRoute training configuration."""

MODEL_NAME = "meta-llama/Llama-2-7b-hf"

# Routing
TOP_K_PASSAGES = 4
GATE_HIDDEN = 256
USE_STRAIGHT_THROUGH = True

# Optimization
LEARNING_RATE = 2e-5
NUM_EPOCHS = 5
BATCH_SIZE = 8
OPTIMIZER = "adamw"

# Data
DATASET = "synthetic_longqa_v2"
EVAL_SPLIT = "dev"
NUM_EVAL_EXAMPLES = 50

BASELINES = ["fid", "reranker_pipeline"]

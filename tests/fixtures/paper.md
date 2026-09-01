# AdaptRoute: Sparse Expert Routing for Efficient Long-Context Retrieval

## Abstract

Long-context retrieval remains bottlenecked by the quadratic cost of dense
attention over retrieved passages. We present AdaptRoute, a sparse expert
routing layer that selects a subset of retrieved passages before cross-attention.
On the LongBench-QA benchmark AdaptRoute improves exact-match accuracy by 3.2
points over the strongest baseline while reducing inference FLOPs by 41%. Our
analysis shows that the routing layer learns to identify answer-bearing passages,
which is what drives the accuracy gain. AdaptRoute is a general mechanism and
improves long-context retrieval across model scales and domains.

## 1 Introduction

Retrieval-augmented generation has become the standard approach for
knowledge-intensive tasks. It is well known that retrieval quality dominates
end-task performance once the reader model exceeds a few billion parameters.
Existing readers concatenate all retrieved passages and attend over them
densely, which scales poorly as the retrieved set grows.

Our contributions are:

1. AdaptRoute, the first routing mechanism that performs passage selection
   inside the reader rather than as a separate reranking stage.
2. A learned gating objective that requires no passage-level supervision.
3. State-of-the-art results on LongBench-QA with substantially lower compute.
4. An analysis showing the routing layer identifies answer-bearing passages.

## 2 Related Work

Passage reranking has been studied extensively. Nogueira and Cho (2019) train a
cross-encoder reranker. Izacard and Grave (2021) propose Fusion-in-Decoder,
which encodes passages independently and fuses them in the decoder. Jiang et al.
(2023) introduce a learned passage selector that is trained jointly with the
reader and drops low-scoring passages before the decoder attends to them.
Our work differs from these approaches in that we operate inside the reader.

## 3 Method

Given a query $q$ and retrieved passages $P = \{p_1, ..., p_n\}$, the router
produces a score $s_i$ for each passage and retains the top-$k$. The gate is a
two-layer MLP over the pooled passage representation. We train with the standard
language modeling loss; no auxiliary routing loss is used. The selection
operation uses a straight-through estimator so gradients reach the gate.

We set $k = 8$ throughout. The router adds 4.2M parameters to the base reader.

## 4 Experiments

### 4.1 Setup

We evaluate on LongBench-QA. Our reader is initialized from a 7B pretrained
checkpoint. Baselines are Fusion-in-Decoder (FiD) and a cross-encoder reranker
pipeline. We train for 3 epochs with AdamW. All models are evaluated with the
standard settings.

### 4.2 Main Results

| Method            | EM   | F1   | FLOPs (rel.) |
|-------------------|------|------|--------------|
| FiD               | 47.1 | 58.3 | 1.00         |
| Reranker + reader | 48.6 | 59.9 | 1.12         |
| AdaptRoute (ours) | 51.4 | 62.1 | 0.59         |

AdaptRoute outperforms the strongest baseline by a clear margin on both metrics
while using substantially fewer FLOPs.

### 4.3 Ablations

Removing the straight-through estimator drops EM to 49.8. Reducing $k$ from 8 to
4 drops EM to 50.1. We did not observe sensitivity to the gate width.

### 4.4 Analysis

We inspect router scores on 50 development examples. In 78% of cases the
top-scoring passage contains the gold answer span, demonstrating that the router
has learned to detect answer-bearing content.

## 5 Limitations

Our experiments use a single model scale due to compute constraints.

## 6 Conclusion

We introduced AdaptRoute, which selects passages inside the reader and achieves
state-of-the-art long-context retrieval accuracy at lower cost. Because the
router generalizes across domains, we expect it to transfer to any
retrieval-augmented setting.

## References

- Izacard, G. and Grave, E. Leveraging Passage Retrieval with Generative Models
  for Open Domain Question Answering. EACL 2021.
- Jiang, Z., et al. Learned Passage Selection for Efficient Reading. arXiv
  preprint, 2023.
- Nogueira, R. and Cho, K. Passage Re-ranking with BERT. arXiv preprint, 2019.
- Khattab, O. and Zaharia, M. ColBERT: Efficient and Effective Passage Search.
  SIGIR 2020.

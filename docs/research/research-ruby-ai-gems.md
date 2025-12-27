# Top 20 Ruby Gems for AI APIs and Recent API Endpoints

**Date:** 2025-12-27
**Purpose:** Survey of Ruby AI/ML ecosystem to inform Kozo design
**Focus:** Gems created or significantly updated 2023-2025

---

## Overview

The Ruby AI ecosystem has experienced unprecedented growth since ChatGPT's launch
in November 2022. Nearly all top AI gems were created or received major updates
in 2023-2025, representing a distinct wave of development separate from the
established API wrapper ecosystem.

---

## Top 20 AI/ML Ruby Gems - Ranked by Downloads

### 1. langchainrb - 826,781+ downloads

| Field | Value |
|-------|-------|
| API | Multiple LLM providers (unified interface) |
| First Released | April 2023 |
| Latest Update | October 2024 |
| Repository | github.com/andreibondarev/langchainrb |

**Description:** Build LLM-powered applications in Ruby

**Supports:**
- OpenAI, Anthropic, Google Gemini, AWS Bedrock
- Hugging Face, Mistral, Cohere, Replicate, Ollama

**Features:**
- RAG architecture
- Vector databases (Pinecone, Qdrant, Milvus, Chroma)
- Embeddings and agents

**Notable:** Most comprehensive Ruby LLM framework with 500+ dependencies

---

### 2. anthropic - 551,120+ downloads

| Field | Value |
|-------|-------|
| API | Anthropic Claude API |
| Latest Update | December 2025 |
| Ruby Version | 3.2.0+ |
| Repository | github.com/anthropics/anthropic-sdk-ruby |

**Description:** Official Anthropic SDK for Ruby

**Supports:** Claude 3.5 Sonnet, Claude 3 Opus, Claude 3 Haiku, streaming, tool use

---

### 3. ruby_llm - 297,728+ downloads

| Field | Value |
|-------|-------|
| API | OpenAI, Anthropic, Gemini, VertexAI, Bedrock, DeepSeek, Mistral, Ollama, OpenRouter, Perplexity, GPUStack |
| Released | 2024 |
| Website | rubyllm.com |
| Repository | github.com/crmne/ruby_llm |

**Description:** One beautiful Ruby API for multiple LLM providers

**Features:**
- Unified chat interface
- Streaming
- File/image handling
- Async processing
- 500+ models registry

**Notable:** Battle-tested in production applications

---

### 4. ruby-openai - Millions of downloads (community gem)

| Field | Value |
|-------|-------|
| API | OpenAI GPT, DALL-E, Whisper |
| First Released | 2020 |
| Latest | v8.2.0 (August 2025) |
| Repository | github.com/alexrudall/ruby-openai |

**Description:** Community-maintained OpenAI client (now superseded by official gem)

**Features:** GPT-4, chat completion, streaming, function calling, vision, embeddings

**Notable:** Was primary OpenAI gem before official release; supports Groq, Ollama, Gemini compatibility

---

### 5. openai (official) - New (March 2025)

| Field | Value |
|-------|-------|
| API | OpenAI |
| Released | March 2025 |
| Ruby Version | 3.2.0+ |
| Repository | github.com/openai/openai-ruby |

**Description:** Official Ruby SDK for OpenAI REST API

**Features:** GPT-5, GPT-4, DALL-E 3, Whisper, embeddings, assistants, streaming

**Notable:** Official SDK replacing community gem ruby-openai

---

### 6. ruby-anthropic - 161,214+ downloads

| Field | Value |
|-------|-------|
| API | Anthropic Claude |
| Status | Community gem (superseded by official) |

**Description:** Community-maintained Anthropic client

**Notable:** Listed as dependency in langchainrb

---

### 7. hugging-face - 23,543+ downloads

| Field | Value |
|-------|-------|
| API | Hugging Face Inference API & Endpoints |
| First Released | May 2023 |
| Latest | v0.3.5 (January 2024) |
| Repository | github.com/alchaplinsky/hugging-face |

**Description:** Ruby client for Hugging Face APIs

**Features:** Text generation, embeddings, sentiment analysis, inference endpoints

**Notable:** Free inference API for prototyping

---

### 8. ruby-openai-swarm - 6,683+ downloads

| Field | Value |
|-------|-------|
| API | OpenAI Swarm (multi-agent orchestration) |
| Latest | v0.5.3 (March 2025) |

**Description:** Ruby implementation of OpenAI's Swarm multi-agent framework

---

### 9. mistral-ai - 3,200+ downloads

| Field | Value |
|-------|-------|
| API | Mistral AI LLMs |
| Released | February 2024 |
| Latest | v1.2.0 |
| Repository | github.com/gbaptista/mistral-ai |

**Description:** Ruby gem for interacting with Mistral AI's models

**Features:** Chat completions, embeddings, model listing, streaming

**Uses:** Faraday with Typhoeus adapter

---

### 10. replicate-ruby

| Field | Value |
|-------|-------|
| API | Replicate (run AI models via API) |
| Released | 2023 |
| Repository | github.com/dreamingtulpa/replicate-ruby |

**Description:** Ruby client for Replicate API

**Features:** Run 1000s of AI models (FLUX, Stable Diffusion, GPT, etc.)

**Notable:** Dependency of langchainrb

---

### 11. replicate-rails

| Field | Value |
|-------|-------|
| API | Replicate |
| Released | 2023 |
| Repository | github.com/dreamingtulpa/replicate-rails |

**Description:** Replicate gem with Rails webhook support

**Features:** Bundles replicate-ruby with Rails-specific features

---

### 12. ruby-gemini-ai

| Field | Value |
|-------|-------|
| API | Google Gemini via Vertex AI & Generative Language API |
| Released | February 2024 |
| Repository | github.com/gbaptista/gemini-ai |

**Description:** Communicate with Gemini via Vertex AI, Generative Language API, or AI Studio

**Features:** Multimodal inputs (text, images, video), streaming, embedded content

---

### 13. google-cloud-ai_platform-v1

| Field | Value |
|-------|-------|
| API | Google Vertex AI Platform |
| Updated | October 2025 |

**Description:** Ruby client for Vertex AI V1 API

**Features:** Train ML models, access Gemini models, Model Garden with Gemini, Claude, Llama

**Use Cases:** Gemini prompting, fine-tuning, deployment, AI agents

---

### 14. ollama-ai

| Field | Value |
|-------|-------|
| API | Ollama (local LLM runtime) |
| Released | 2024 |
| Latest | v1.2.1 |
| Repository | github.com/gbaptista/ollama-ai |

**Description:** Ruby gem for Ollama API interactions

**Features:** Local model execution, embeddings, vision models (llava)

**Use Case:** Running LLMs locally without cloud APIs

---

### 15. ollama-ruby

| Field | Value |
|-------|-------|
| API | Ollama |
| Latest | v1.18.0 (December 2025) |

**Description:** Library for Ollama local model interactions

---

### 16. deepseek-client - New (February 2025)

| Field | Value |
|-------|-------|
| API | DeepSeek AI |
| Released | February 2025 |

**Description:** Ruby SDK for DeepSeek AI models

**Notable:** Went viral on Reddit with 75 upvotes

**Controversy:** DeepSeek API is OpenAI-compatible, questioning need for dedicated gem

---

### 17. deepseek-ruby - Alternative (January 2025)

| Field | Value |
|-------|-------|
| API | DeepSeek AI |
| Released | January 2025 |

**Description:** Another Ruby client for DeepSeek API

---

### 18. perplexity_api - New (2024-2025)

| Field | Value |
|-------|-------|
| API | Perplexity AI |
| Released | 2024 |
| Latest | v0.5.0 (January 2025) |
| Repository | github.com/davidjrice/perplexity |

**Description:** Ruby wrapper for Perplexity AI API

**Features:** Streaming support, connection pooling, request builder

---

### 19. perplexity - Alternative (April 2024)

| Field | Value |
|-------|-------|
| API | Perplexity AI |
| Released | April 2024 |

**Description:** Unofficial Ruby client for Perplexity AI

---

### 20. durable_huggingface_hub - Latest (October 2025)

| Field | Value |
|-------|-------|
| API | HuggingFace Hub |
| Released | October 2025 |
| Version | v0.2.0 |

**Description:** Complete production-ready Ruby HuggingFace Hub client

**Features:**
- Download models/datasets
- Smart caching
- Zero Python dependencies
- Progress tracking

---

## Key Insights

### Explosive AI Gem Growth

The Ruby AI ecosystem has experienced unprecedented growth since ChatGPT's launch
in November 2022. Nearly all top AI gems were created or received major updates
in 2023-2025.

### Unified Interface Trend

Gems like `ruby_llm` and `langchainrb` provide abstraction layers over multiple
AI providers, reflecting developer preference for provider-agnostic code. This
mirrors patterns seen in Python's LangChain ecosystem.

### Official SDKs Emerging

Major AI providers now publish official Ruby SDKs (OpenAI, Anthropic), replacing
earlier community gems. This signals Ruby's legitimacy in AI/ML development
circles despite Python's dominance.

### Local-First Options

Ollama gems enable running LLMs locally without API costs or internet
dependencies, appealing to privacy-conscious developers and reducing inference
costs.

### RAG Infrastructure

LangChainRB's 826K+ downloads and comprehensive vector database support indicate
significant Ruby adoption for Retrieval-Augmented Generation architectures.

### DeepSeek Controversy

The January 2025 viral discussion around DeepSeek gems highlights a broader
ecosystem question: when APIs are OpenAI-compatible, do dedicated gems add value
or fragment the ecosystem?

### Provider Diversity

Ruby developers now access 10+ major LLM providers:
- OpenAI
- Anthropic
- Google (Gemini/Vertex)
- Mistral
- DeepSeek
- Perplexity
- Replicate
- Ollama
- Hugging Face
- Cohere

With unified gems supporting easy provider switching.

### Enterprise Readiness

Gems like `durable_huggingface_hub` and `langchainrb` emphasize production
features (caching, error handling, comprehensive types), indicating Ruby AI
applications moving beyond prototyping.

### Download Disparity

AI gems show 100-1000x fewer downloads than established infrastructure gems:
- AWS SDK: 1.5B downloads
- langchainrb: 826K downloads

This reflects AI's recent emergence and Python's ecosystem advantage. However,
growth rates are exceptional.

### Replicate's Position

With 1000s of AI models available via API, Replicate gems enable Ruby developers
to experiment with cutting-edge models (FLUX, Stable Diffusion, etc.) without
model hosting complexity.

---

## Implications for Kozo

### Patterns Worth Adopting

1. **Unified interfaces** - ruby_llm and langchainrb show value of provider abstraction
2. **Streaming as first-class** - All major AI gems support streaming responses
3. **Local-first options** - Ollama integration shows demand for offline/private operation

### Error Handling Gaps

AI API gems face the same gaps as traditional API gems:
- Rate limiting is manual
- Retry logic is caller's responsibility
- Circuit breakers are absent
- Token budget management varies

### Opportunity

Kozo could provide infrastructure that AI gems (and their unified interfaces)
build upon, handling the networking resilience so they can focus on AI-specific
concerns.

---

## Sources

Research compiled from 75 sources including:
- RubyGems.org gem pages and statistics
- GitHub repositories and release notes
- Reddit discussions (r/rails, r/ruby)
- Developer blog posts and tutorials
- Official documentation

Full citation list available in project research archives.

# Maple Leaf Bank assistant (the workload)

The same small app used in [ai-quality-engineer](https://github.com/vnigam1985/ai-quality-engineer). There it's the system under test. Here it's the **workload your platform hosts**: a RAG chatbot plus an agent that can move money, which is exactly the kind of app a bank's AI platform has to make safe.

| Setting | Local (week 0) | AWS (week 5+) |
| --- | --- | --- |
| `LLM_MODE` | `llm` | `llm` |
| `OPENAI_BASE_URL` | `http://litellm:4000/v1` | `http://<internal ALB>:4000/v1` |
| `OPENAI_API_KEY` | Local team key | Team key from Secrets Manager, injected by ECS |
| `MODEL` | `bank-chat` | `bank-chat` (the gateway maps it to Bedrock) |

The app never holds AWS credentials or a model key. It only knows the gateway.

# The AI gateway image: LiteLLM plus our config. Built on your laptop and pushed
# to your private ECR (make week4-images), because the VPC can't reach ghcr.io.
FROM ghcr.io/berriai/litellm:main-stable
COPY config.yaml /app/config.yaml
CMD ["--config", "/app/config.yaml", "--port", "4000"]

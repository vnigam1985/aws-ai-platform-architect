#!/usr/bin/env bash
# Build an image on your laptop and push it to the lab's private ECR.
# Usage: push-images.sh gateway|app <region> <prefix> [tag]
# The VPC has no internet, so ECS can only pull from your own ECR.
set -euo pipefail
WHAT=$1; REGION=$2; PREFIX=$3; TAG=${4:-v1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REG"
case "$WHAT" in
  gateway) REPO="$REG/$PREFIX/ai-gateway"; docker build --platform linux/amd64 -t "$REPO:$TAG" "$ROOT/infra/week04-ai-gateway/gateway" ;;
  app)     REPO="$REG/$PREFIX/maple-bank-assistant"; docker build --platform linux/amd64 -t "$REPO:$TAG" -f "$ROOT/app/Dockerfile" "$ROOT" ;;
  *) echo "usage: $0 gateway|app <region> <prefix> [tag]"; exit 1 ;;
esac
docker push "$REPO:$TAG"
echo "Pushed $REPO:$TAG"

# AgriVision — most-repeated dev commands.
# Server targets run inside server/ (need server/.venv and server/.env).
# iOS targets need Xcode with the iPhone 17 Pro simulator installed.

GCP_PROJECT := agritrack-465917
GCP_REGION  := europe-west1
SERVICE     := carnivision-embedder
IMAGE       := gcr.io/$(GCP_PROJECT)/$(SERVICE)
TAG         ?= latest
SIM_DEST    := platform=iOS Simulator,name=iPhone 17 Pro

.PHONY: help server-test server-test-all setup-db ios-build ios-test ios-release \
        deploy-build deploy-run deploy health logs

help: ## List available targets
	@grep -E '^[a-z][a-zA-Z-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

# ---- Server (FastAPI embedder) ----

server-test: ## Fast server test suite (no model load, no network)
	cd server && .venv/bin/pytest tests/ -m "not slow" -q

server-test-all: ## Full server suite including slow model tests
	cd server && .venv/bin/pytest tests/ -q

setup-db: ## Apply schema + verify bucket/policies/test user (uses server/.env)
	cd server && .venv/bin/python scripts/setup_supabase.py

# ---- iOS app ----

ios-build: ## Debug build for the simulator
	xcodebuild -project AgriVision.xcodeproj -scheme AgriVision \
	  -destination '$(SIM_DEST)' build

ios-test: ## Run the iOS test suite on the simulator
	xcodebuild -project AgriVision.xcodeproj -scheme AgriVision \
	  -destination '$(SIM_DEST)' test

ios-release: ## Release-configuration build (catches release-only errors)
	xcodebuild -project AgriVision.xcodeproj -scheme AgriVision \
	  -configuration Release -destination '$(SIM_DEST)' build

# ---- Cloud Run deploy (override tag: make deploy TAG=events) ----

deploy-build: ## Build + push the embedder image with Cloud Build
	gcloud builds submit server --project $(GCP_PROJECT) --tag $(IMAGE):$(TAG)

deploy-run: ## Deploy the pushed image (env/secrets/scaling preserved)
	gcloud run deploy $(SERVICE) --project $(GCP_PROJECT) --region $(GCP_REGION) \
	  --image $(IMAGE):$(TAG)

deploy: deploy-build deploy-run health ## Build, deploy, then health-check

health: ## Hit the live /health endpoint
	@URL=$$(gcloud run services describe $(SERVICE) --project $(GCP_PROJECT) \
	  --region $(GCP_REGION) --format 'value(status.url)'); \
	echo "$$URL/health"; curl -s "$$URL/health"; echo

logs: ## Tail recent Cloud Run logs
	gcloud run services logs read $(SERVICE) --project $(GCP_PROJECT) \
	  --region $(GCP_REGION) --limit 50

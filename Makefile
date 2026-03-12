# ─────────────────────────────────────────────────────────────────────────────
# NexusDeploy Makefile - Developer workflow shortcuts
# Usage: make <target> [ENV=dev] [REGION=us-east-1]
# ─────────────────────────────────────────────────────────────────────────────

ENV    ?= dev
REGION ?= us-east-1
PROJECT = nexusdeploy
TF_DIR  = terraform/environments/$(ENV)
TF_STATE_BUCKET = $(PROJECT)-terraform-state
TF_LOCK_TABLE   = $(PROJECT)-terraform-locks

.DEFAULT_GOAL := help

.PHONY: help bootstrap test lint build push deploy tf-init tf-plan tf-apply tf-destroy \
        cleanup logs status shell

# ── Help ──────────────────────────────────────
help:
	@echo ""
	@echo "NexusDeploy DevOps Makefile"
	@echo "══════════════════════════════════════"
	@echo ""
	@echo "Setup:"
	@echo "  make bootstrap          One-time AWS infrastructure setup"
	@echo ""
	@echo "Development:"
	@echo "  make test               Run all tests with coverage"
	@echo "  make lint               Run linters (flake8, black, bandit)"
	@echo "  make build              Build Docker images locally"
	@echo "  make up                 Start local dev with docker-compose"
	@echo "  make down               Stop local dev environment"
	@echo ""
	@echo "Terraform (ENV=dev|staging|prod):"
	@echo "  make tf-init  ENV=dev   Initialize Terraform backend"
	@echo "  make tf-plan  ENV=dev   Plan infrastructure changes"
	@echo "  make tf-apply ENV=dev   Apply infrastructure changes"
	@echo "  make tf-destroy ENV=dev Destroy environment (non-prod only)"
	@echo ""
	@echo "Operations:"
	@echo "  make deploy ENV=dev     Full deploy: build + push + tf-apply"
	@echo "  make cleanup ENV=dev    Run cleanup script (fallback)"
	@echo "  make logs ENV=dev       Tail ECS logs in CloudWatch"
	@echo "  make status ENV=dev     Show ECS service status"
	@echo "  make shell ENV=dev      ECS Exec into running API container"
	@echo ""

# ── Setup ─────────────────────────────────────
bootstrap:
	@echo "🚀 Running one-time bootstrap..."
	@chmod +x scripts/bootstrap.sh
	@AWS_REGION=$(REGION) PROJECT=$(PROJECT) ./scripts/bootstrap.sh

# ── Local Dev ─────────────────────────────────
up:
	docker-compose up -d
	@echo "✅ Local environment started"
	@echo "   API:           http://localhost:5000"
	@echo "   Swagger UI:    http://localhost:5000/apidocs"
	@echo "   Redis UI:      http://localhost:8081"

down:
	docker-compose down -v

# ── Testing ───────────────────────────────────
test:
	@echo "🧪 Running tests..."
	cd app && pytest tests/ -v --cov=src --cov-report=term-missing --cov-report=html
	@echo "📊 Coverage report: app/htmlcov/index.html"

lint:
	@echo "🔍 Running linters..."
	cd app && flake8 src/ --max-line-length=120
	cd app && black --check src/
	cd app && bandit -r src/ -ll -x src/tests/ || true
	@echo "✅ Lint complete"

# ── Docker ────────────────────────────────────
build:
	@echo "🐳 Building Docker images..."
	docker build -t $(PROJECT)-api:local -f app/Dockerfile app/
	docker build -t $(PROJECT)-worker:local -f app/Dockerfile.worker app/
	@echo "✅ Images built"

push: ecr-login
	@echo "📤 Pushing Docker images to ECR..."
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	ECR_REGISTRY=$$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com; \
	docker tag $(PROJECT)-api:local $$ECR_REGISTRY/$(PROJECT)-api:latest; \
	docker tag $(PROJECT)-worker:local $$ECR_REGISTRY/$(PROJECT)-worker:latest; \
	docker push $$ECR_REGISTRY/$(PROJECT)-api:latest; \
	docker push $$ECR_REGISTRY/$(PROJECT)-worker:latest; \
	@echo "✅ Images pushed to ECR"

deploy: build push tf-apply
	@echo "✅ Deployment complete (build → push → tf-apply)"

# ── Terraform ─────────────────────────────────
tf-init:
	@echo "🔧 Initializing Terraform for $(ENV)..."
	cd $(TF_DIR) && terraform init \
		-backend-config="bucket=$(TF_STATE_BUCKET)" \
		-backend-config="key=$(ENV)/terraform.tfstate" \
		-backend-config="region=$(REGION)" \
		-backend-config="dynamodb_table=$(TF_LOCK_TABLE)" \
		-backend-config="encrypt=true"

tf-plan: tf-init
	@echo "📋 Planning Terraform for $(ENV)..."
	cd $(TF_DIR) && terraform plan -var-file=terraform.tfvars -out=tfplan

tf-apply: tf-init
	@echo "🚀 Applying Terraform for $(ENV)..."
	cd $(TF_DIR) && terraform apply -var-file=terraform.tfvars -auto-approve

tf-destroy:
	@if [ "$(ENV)" = "prod" ]; then \
		echo "❌ Direct destroy of prod is not allowed."; \
		echo "   Retrieve state: aws s3 cp s3://$(TF_STATE_BUCKET)/prod/terraform.tfstate ./prod.tfstate"; \
		echo "   Then: terraform destroy"; \
		exit 1; \
	fi
	@echo "⚠️  Destroying $(ENV) environment in 5 seconds... (Ctrl+C to cancel)"
	@sleep 5
	cd $(TF_DIR) && terraform destroy -var-file=terraform.tfvars -auto-approve

tf-fmt:
	terraform fmt -recursive terraform/

tf-validate:
	@for env in dev staging prod; do \
		echo "Validating $$env..."; \
		(set -e; cd terraform/environments/$$env && terraform init -backend=false -input=false && terraform validate) || exit 1; \
	done

# ── Operations ────────────────────────────────
CLUSTER_NAME = $(PROJECT)-$(ENV)

status:
	@echo "📊 ECS Service Status for $(ENV):"
	@aws ecs list-services --cluster $(CLUSTER_NAME) --region $(REGION) \
		--query 'serviceArns[]' --output table
	@aws ecs describe-services \
		--cluster $(CLUSTER_NAME) \
		--services $(PROJECT)-$(ENV)-api $(PROJECT)-$(ENV)-worker $(PROJECT)-$(ENV)-beat \
		--region $(REGION) \
		--query 'services[].{Name:serviceName,Running:runningCount,Desired:desiredCount,Status:status}' \
		--output table

logs:
	@echo "📜 Tailing logs for $(ENV)/api (Ctrl+C to stop):"
	aws logs tail /ecs/$(PROJECT)/$(ENV)/api \
		--region $(REGION) \
		--follow \
		--format short

# ECS Exec - SSH into a running container (requires SSM agent)
shell:
	@TASK_ARN=$$(aws ecs list-tasks \
		--cluster $(CLUSTER_NAME) \
		--service-name $(PROJECT)-$(ENV)-api \
		--region $(REGION) \
		--query 'taskArns[0]' \
		--output text); \
	echo "🐚 Connecting to task: $$TASK_ARN"; \
	aws ecs execute-command \
		--cluster $(CLUSTER_NAME) \
		--task $$TASK_ARN \
		--container api \
		--interactive \
		--command "/bin/sh" \
		--region $(REGION)

cleanup:
	@echo "🧹 Running cleanup for $(ENV)..."
	@chmod +x scripts/cleanup.sh
	./scripts/cleanup.sh --env $(ENV) --region $(REGION)

cleanup-dry:
	@chmod +x scripts/cleanup.sh
	./scripts/cleanup.sh --env $(ENV) --region $(REGION) --dry-run

# ── ECR ───────────────────────────────────────
ecr-login:
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	aws ecr get-login-password --region $(REGION) | \
		docker login --username AWS \
		--password-stdin $$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com

# Dump current state to local for prod manual destroy
prod-state-download:
	@echo "📥 Downloading prod state file for local destroy..."
	aws s3 cp \
		s3://$(TF_STATE_BUCKET)/prod/terraform.tfstate \
		./prod-terraform.tfstate
	@echo "✅ Saved to ./prod-terraform.tfstate"
	@echo "   To destroy: terraform destroy -state=prod-terraform.tfstate"

# ── Monitoring ────────────────────────────────
monitoring-url:
	@terraform -chdir=terraform/environments/$(ENV) output -raw grafana_url 2>/dev/null \
		|| echo "Run 'make tf-apply ENV=$(ENV)' first"

monitoring-logs:
	@echo "📜 Monitoring EC2 setup log:"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--region $(REGION) \
		--filters \
			"Name=tag:Project,Values=$(PROJECT)" \
			"Name=tag:Environment,Values=$(ENV)" \
			"Name=tag:Role,Values=monitoring" \
		--query 'Reservations[0].Instances[0].InstanceId' \
		--output text); \
	aws ssm start-session \
		--target $$INSTANCE_ID \
		--document-name AWS-StartInteractiveCommand \
		--parameters '{"command":["tail -f /var/log/monitoring-setup.log"]}' \
		--region $(REGION)

# ── Prod Blue-Green ───────────────────────────
prod-active-slot:
	@aws ssm get-parameter \
		--name "/nexusdeploy/prod/deployment/active_slot" \
		--region $(REGION) \
		--query 'Parameter.Value' \
		--output text

# ── Secrets ───────────────────────────────────
secrets:
	@echo "🔐 Creating SSM secrets for ENV=$(ENV)..."
	@ENV=$(ENV) AWS_REGION=$(REGION) ./scripts/bootstrap.sh
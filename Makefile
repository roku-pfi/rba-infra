# One-word entry points. Each target is a script in scripts/; read it for the details.

.PHONY: help aws-up aws-down aws-plan images k3d-up k3d-down e2e

help:
	@echo "make aws-up     build + push images, create the runtime stack, deploy, re-point CloudFront (≈US\$$0.27/h until aws-down)"
	@echo "make aws-down   uninstall, wait for the ALB to go, destroy the runtime stack (back to ≈US\$$1/month)"
	@echo "make aws-plan   show what aws-up would create, without creating anything"
	@echo "make images     check every image builds for arm64 + amd64 (no push)"
	@echo "make k3d-up     local cluster (k3d + Helm)"
	@echo "make k3d-down   delete the local cluster"
	@echo "make e2e        browser tests of the scenario map against the running cluster"

aws-up:
	scripts/aws-up.sh

aws-down:
	scripts/aws-down.sh

aws-plan:
	AWS_PROFILE=$${AWS_PROFILE:-rokusec} tofu -chdir=tofu/runtime plan -input=false

images:
	scripts/build-images.sh

k3d-up:
	scripts/k3d-up.sh

k3d-down:
	scripts/k3d-down.sh

warm-up:  ## usual history through the real login: make warm-up WHO="martin diego" N=10 [TARGET=aws]
	TARGET=$(or $(TARGET),k3d) scripts/warm-up.sh $(or $(WHO),martin) -n $(or $(N),10)

e2e:
	scripts/e2e.sh

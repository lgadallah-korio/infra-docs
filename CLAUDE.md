# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Repository Overview

This is **not** a single git repository — it is a parent directory
containing **independent git repos** for Korio Clinical's DevOps
infrastructure. Each subdirectory has its own `.git`, CI/CD, and
tooling. Always `cd` into the relevant subdirectory before running git
or build commands.

## Business Context

Korio operates in the IRT (Interactive Response Technology) space for
clinical trials. Traditional IRT companies build and maintain a
separate solution per client, which creates significant scaling costs
as the client base grows. Korio's approach is to build a
multi-tenant platform that maximizes code reuse across clients,
reducing the marginal cost of onboarding each new client. This
goal is reflected in the architecture: a shared codebase and Helm
chart parameterized per client, manifest-driven deployments, and a
standardized multi-environment pipeline rather than bespoke
per-client infrastructure.

A key constraint is that once a client takes delivery of their
system, they go through a formal validation and acceptance process
that is time-consuming and expensive. Clients therefore typically
require that no code changes be made to their system after
acceptance. This drives the need for strict version pinning
per-client and explains the sub-environment pipeline
(`configure` → `preview` → `validate` → `accept` → `my`), which
maps onto the client's validation lifecycle.

Korio takes an unconventional approach to managing this constraint.
Rather than maintaining separate deployments per client, each
microservice exposes each client's version on its own web
path/route, and each unique path/route is mapped to a specific git
branch representing that client's accepted version of the service.
Git branches therefore serve as the feature/version management
mechanism across the client base.

**The NGINX API gateway is the key tool that makes this work.**
NGINX routing rules are what bind each client's URL path to their
pinned git branch/version of each service. Managing these routing
configs correctly is therefore critical to the integrity of the
whole system — a misconfigured route could send a client to the
wrong version of a service.

Deploying ~50 services across 9 environments and 5 sub-environments
means hundreds of ArgoCD Application/ApplicationSet YAML files must
be kept in sync. This drove the creation of **presto-besto-manifesto**:
a manifest-driven system that lets developers declare only three
attributes per service (container image, env vars, secrets), and
automates generation of all the YAML files ArgoCD needs to deploy to
AKS. It is the primary interface for controlling what gets deployed where.

## Environments

`dev` → `test` → `platform` → `staging` → `prod` (plus `platform3`,
`staging3`, `prod3` for ReCode/v3 variants, and `sandbox` for
experiments).

## Sub-environments

`configure` → `preview` → `validate` → `accept` → `my`

## Topic Guides

Detailed reference documentation is split by domain:

- **[Application Stack](application-stack.md)** — NGINX routing
  and request flow, korioctl, dagger-presto, ArgoCD, Helm chart
  architecture, presto-besto-manifesto, Docker local dev, microservice
  deployment lifecycle, CI workflows, Azure B2C integration
- **[Infrastructure](infrastructure.md)** — External dependencies
  (Cloudflare, B2C, MongoDB Atlas, Twingate), Terraform, deployment
  flow, sub-environment configuration and provisioning checklist
- **[SFTP](sftp.md)** — sftp-server-docker, sftp-acl-init-go,
  Kustomize deployment architecture, Azure Workload Identity
  (UAMI/FIC/DLDP), CI workflows
- **[Observability](observability.md)** — Datadog agent deployment
  and integrations (ArgoCD, MongoDB), Azure Monitor (managed Prometheus,
  Container Insights, Log Analytics), Grafana dashboards and RBAC,
  alerting (Prometheus rules, Atlas alerts), PagerDuty escalation,
  log sampling and cost control, Terraform workspace layout

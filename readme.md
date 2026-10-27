# DevSecOps 2026 Pipeline — Post-Mortem & Improvement Plan

This repository contains a small Python HTTP service (`app/main.py`), a hardened multi-stage `Dockerfile`, a security-constrained `docker-compose.yml`, and a GitHub Actions DevSecOps pipeline (`.github/workflows/devsecops-pipeline.yml`).

Following a recent incident review of the build/scan/push pipeline, this document records **what went wrong**, the **post-mortem remediations** applied or planned, and **what we will improve next**.

---

## What Went Wrong — Post-Mortem & Remediation

| # | Issue (What Went Wrong) | Root Cause | Impact | Remediation | Status |
|---|-------------------------|------------|--------|-------------|--------|
| 1 | **Vulnerability scan cannot fail the build** — Trivy's `exit-code: '1'` was commented out, so CRITICAL/HIGH findings were reported but the pipeline always "passed". | Gate disabled during an earlier noisy-scan outage and never re-enabled. | Vulnerable images flowed straight to the registry; scanning became purely cosmetic. | Re-enable `exit-code: '1'` on the Trivy step and enforce a break-the-build gate on CRITICAL/HIGH. Track exceptions in `.trivyignore` with owner + expiry date. | Planned |
| 2 | **Image pushed as mutable `:latest`** — the push step tags only `ghcr.io/.../my-devsecops-app:latest`, contradicting the compose file's own rule ("never use :latest"). | Copy-paste from a quickstart template; no tag policy in code review checklist. | Non-reproducible deployments; impossible to roll back to a known-good digest; supply-chain risk via tag hijacking. | Push immutable tags (`sha-<commit>` and semver), deploy by digest, and enable GHCR image retention/untag policy. | Planned |
| 3 | **Secrets exposed in job logs / over-broad token permissions** — pipeline-level `permissions` grant `packages: write` and `security-events: write` to *every* job/event, including fork PRs; `${{ github.actor }}` + full-write tokens logged context repeatedly. | Permissions set at workflow level instead of least-privilege per job. | A compromised or malicious PR job could write packages and alter security data; log hygiene risk. | Scope `permissions` per job (checkout/scan jobs: `contents: read` only); gate push jobs behind environment protection; mask/limit echoed context in logs. | Planned |
| 4 | **Unpinned third-party actions** — `actions/checkout@v4`, `docker/*`, `codeql-action/upload-sarif@v3` resolve to moving tags while only Trivy was pinned to a SHA. | Inconsistent hardening guidance across the team. | Supply-chain exposure: a tag moved upstream silently changes executed code. | Pin **all** actions to full commit SHAs with version comments; enable Dependabot/GitHub patch alerts for Actions. | Planned |
| 5 | **Healthcheck can never pass correctly** — the compose healthcheck runs `python` inside a distroless image where no shell/`CMD` array interpreter exists as expected, so the container is permanently reported unhealthy. | Healthcheck written for a slim image, not adapted after migration to distroless. | Restart loops / orchestrator kills in production; alert fatigue masking real incidents. | Replace with an app-level TCP probe strategy appropriate for distroless (or include a static health-check binary built in Stage 1), and verify in CI before merge. | Planned |
| 6 | **Build cache poisoning window** — `cache-to: type=gha,mode=max` writes caches even on PR builds from forks, and cached layers were reused into main builds without attestation. | Cache configuration copied from performance guide without security review. | Attacker-controlled PR could influence layers of the trusted image. | Restrict cache writes to `main` pushes only (`cache-to` conditional), or move to registry cache with signed provenance verification. | Planned |
| 7 | **SARIF upload ran against protected branch from PR contexts** — `upload-sarif` with `if: always()` executes on fork PRs where `security-events: write` is silently downgraded, producing confusing failures/no-op uploads. | Mismatch between declared permissions and GitHub's fork-PR token rules. | Security tab gaps looked like "no findings" when they were actually failed/skipped uploads. | Upload SARIF only from same-repo push events; for PRs keep the artifact + comment; add explicit check that upload succeeded. | Planned |
| 8 | **Server binds `0.0.0.0` inside the app** while compose intends a localhost-only exposure — defense-in-depth relied on one layer only; once deployed to a container platform the port is reachable on all interfaces. | Hardcoded bind address in `app/main.py`; network boundary assumed rather than enforced. | Unintended external exposure of the service. | Make bind address/port configurable via env vars, default to loopback; document the network boundary and add egress/ingress checks in the release checklist. | Planned |
| 9 | **No base-image pinning or digest verification** — `FROM python:3.12-slim` and `gcr.io/distroless/python3-debian12:nonroot` float on tags rebuilt upstream. | Trust placed in publisher tags without digest pinning. | Silent behavior/security changes on rebuild; non-reproducible builds. | Pin base images by digest (`@sha256:...`), refresh via Renovate, and verify digests match SBOM/provenance attestations. | Planned |
| 10 | **Incident response gap: no SBOM, provenance, or audit trail** — when a vulnerable dependency surfaced post-release, we could not answer "which image contains which package version, built from which commit, by whom?" | Build-and-push flow produced no artifacts for traceability. | Slow blast-radius analysis; compliance findings; hours of manual reconstruction during the incident. | Generate CycloneDX SBOM and SLSA provenance attestations at build time, attach them to the GHCR image, and retain build logs; add a documented runbook for vulnerability disclosure. | Planned |

---

## Things to Improve (Next Iteration)

1. **Fail-closed scanning:** re-enable `exit-code: '1'` plus a managed `.trivyignore` with expiring exceptions, so unpatched CRITICAL/HIGH vulnerabilities block promotion automatically.
2. **Immutable tagging & promotion:** tag images as `sha-<full-sha>` and semantic versions, promote by digest through dev → staging → prod instead of rebuilding per environment.
3. **Per-job least-privilege `permissions`:** every job declares exactly what it needs; push/deploy jobs require a protected GitHub Environment with required reviewers.
4. **Pin every action and base image to a digest/SHA**, with Renovate keeping pins fresh — eliminate all floating `@vN` tags and mutable base tags.
5. **Add static analysis gates:** Semgrep/Bandit for the Python app, hadolint for the Dockerfile, actionlint + zizmor for the workflow itself, all wired into PR checks.
6. **SBOM + provenance attestation:** emit CycloneDX SBOM and SLSA build provenance on every image; wire Dependency-Review into PRs for license/vuln visibility.
7. **Test the runtime path in CI:** spin up the compose service in the pipeline and assert the healthcheck passes, so broken healthchecks (issue #5) can never merge again.
8. **Observability & alerting:** structured logging with request IDs, container metrics, and an alert when scans report new CRITICAL/HIGH findings on `main`.
9. **Branch protections & CODEOWNERS:** require green pipeline + security review for changes to `Dockerfile`, `docker-compose.yml`, and `.github/workflows/**`.
10. **Runbook & game day:** document rollback-by-digest, secret rotation, and vulnerability-disclosure steps; run a quarterly incident simulation to validate them.

---

## Development Notes

### Run locally

```bash
docker compose up --build
curl http://127.0.0.1:8080
```

### Pipeline overview

`build (load) → trivy scan (SARIF) → upload SARIF → (main only) login GHCR → push`

See `.github/workflows/devsecops-pipeline.yml` for the current implementation and the table above for its known deficiencies.

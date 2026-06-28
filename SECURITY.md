# Security Policy

## Supported Versions

This project follows a single-branch production model. Only the code currently deployed from `main` is supported.

| Branch           | Supported        |
| ---------------- | ---------------- |
| `main` (current) | Yes              |
| `dev`            | No (pre-release) |
| Older commits    | No               |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, pull requests, or discussions.**

Report vulnerabilities privately via one of these channels:

- **GitHub Private Vulnerability Reporting**: Use the "Report a vulnerability" button in the [Security tab](../../security/advisories/new) of this repository.
- **Email**: Send details to **harshitkandhwey@gmail.com** with the subject line `[SECURITY] Ephemeral Deploy — <brief description>`.

### What to Include

A useful report contains:

- A description of the vulnerability and its potential impact
- The affected component (API endpoint, Terraform module, CI workflow, etc.)
- Steps to reproduce or proof-of-concept code
- Any suggested mitigations you have identified

### Response Timeline

| Stage              | Target                                              |
| ------------------ | --------------------------------------------------- |
| Acknowledgement    | Within 48 hours                                     |
| Initial assessment | Within 7 days                                       |
| Fix or mitigation  | Depends on severity; critical issues within 14 days |
| Disclosure         | Coordinated with reporter after fix is deployed     |

## Known Security Design Decisions

The following are intentional design choices, not vulnerabilities:

- **Prometheus `/metrics` endpoint is unauthenticated**: It is only reachable within the VPC (port 5000 is restricted to VPC CIDR at the security group level). Prometheus scrapes it without credentials by design.
- **Grype scan is non-blocking**: Container image scans run and report findings but never fail the build. This is a visibility tool, not a hard gate.
- **No Terraform state locking**: The project is a single-developer workflow. Concurrent Terraform runs are not expected.
- **ALB is disabled**: ECS task IPs are used directly. The security group restricts inbound to known sources only.

## Security Controls in Place

- **Secrets**: Never stored in source control. Injected at runtime via AWS Secrets Manager → ECS environment variables.
- **Auth**: JWT with short-lived access tokens (1 hour) and role-based access control (admin / manager / developer).
- **Database**: App connects as a least-privilege `nexusapp` PostgreSQL user, not the RDS master user.
- **Container images**: Scanned with Grype on every CI run.
- **Secret scanning**: GitHub secret scanning is enabled on this repository.
- **Audit logging**: Every mutating API operation is recorded to the `audit_logs` table with user ID, IP address, and changed fields.

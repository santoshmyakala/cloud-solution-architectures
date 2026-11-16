# ADR-0004: Workload identity instead of stored credentials

- **Status:** Accepted
- **Context:** Connection strings and access keys in app settings, pipelines and Kubernetes secrets are the most common credential-leak path.
- **Decision:** Workloads authenticate with platform identities: IAM roles for Lambda and EC2, EKS Pod Identity, Azure managed identity and Workload ID. Key-based auth is **disabled** on data services where the platform allows it.
- **Consequences:** Local development uses developer identities (`az login`, SSO). Some third-party tools without Entra ID or IAM support need a documented exception and secret rotation.

# ADR-0002: Route all spoke traffic through a central inspection hub

- **Status:** Accepted
- **Context:** Per-workload NAT gateways and security groups made egress control inconsistent, and there was no single place to log or block outbound traffic.
- **Decision:** Spokes have no internet path. A hub (AWS Transit Gateway + inspection VPC; Azure hub VNet + Azure Firewall) inspects north-south **and** east-west traffic, with an FQDN allowlist for egress.
- **Consequences:** The firewall is a shared, highly available dependency (multi-AZ or zone-redundant). It adds per-GB processing cost and latency, so high-volume data paths may use private endpoints or VPC endpoints that bypass the firewall, as documented exceptions.

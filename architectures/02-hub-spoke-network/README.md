# 02 · Hub-and-spoke network with central inspection

**Problem:** many workload networks need internet egress, shared services and controlled east-west traffic, without each team running (and misconfiguring) its own firewall.

**Approach:** spokes have **no direct internet path**. All traffic, including spoke-to-spoke, is routed through a central, highly available firewall with an **egress allowlist** and centralised logs.

## AWS: Transit Gateway + inspection VPC + AWS Network Firewall

```mermaid
flowchart LR
  subgraph spokes[Spoke VPCs — private subnets only]
    p[prod 10.10.0.0/16]
    n[nonprod 10.20.0.0/16]
  end
  p & n -->|0.0.0.0/0| tgw{{Transit Gateway<br/>spoke RT: 0/0 → inspection<br/>inspection RT: spoke routes}}
  tgw --> tgwsub[TGW subnets<br/>appliance mode]
  subgraph insp[Inspection VPC 10.0.0.0/16 — per AZ]
    tgwsub -->|0/0| fw[Network Firewall endpoint<br/>stateful TLS-SNI allowlist]
    fw -->|0/0| nat[NAT gateway]
    nat --> igw[Internet gateway]
    igw -.->|return: spoke CIDRs → firewall| fw
  end
  fw -.->|alerts| cw[(CloudWatch Logs)]
```

## Azure: hub VNet + Azure Firewall Premium

```mermaid
flowchart LR
  subgraph spokes[Spoke VNets]
    p[prod 10.110.0.0/22<br/>UDR 0/0 → firewall<br/>no default outbound]
    n[nonprod 10.120.0.0/22<br/>UDR 0/0 → firewall]
  end
  p <-->|peering| hub
  n <-->|peering| hub
  subgraph hub[Hub VNet 10.100.0.0/22]
    afw[Azure Firewall Premium<br/>zones 1-3 · IDPS deny · TI deny<br/>DNS proxy · FQDN allowlist]
    gw[GatewaySubnet<br/>reserved for VPN/ER]
  end
  afw --> internet((Internet))
  afw -.->|allLogs| la[(Log Analytics)]
```

## Same pattern, different mechanics

| Concern | AWS | Azure |
|---|---|---|
| Hub router | Transit Gateway with separate route tables (no default propagation) | VNet peering + user-defined routes |
| Firewall | AWS Network Firewall, one endpoint per AZ | Azure Firewall Premium, zone-redundant |
| Flow symmetry | TGW **appliance mode** + per-AZ routing | Single logical firewall IP |
| Egress control | Stateful domain allowlist (TLS SNI / HTTP Host) | Application rules on FQDNs + DNS proxy |
| Threat detection | Suricata-compatible rules (add managed threat signatures) | IDPS + threat intelligence in **deny** mode |
| Stop implicit egress | No IGW in spokes | `default_outbound_access_enabled = false` |

## Tests assert

- Spokes can't reach the internet directly (no IGW routes, no public IPs, no implicit outbound).
- Every spoke route points at the firewall, including routes to the other spoke.
- Each AWS AZ is steered through **its own** firewall endpoint (checked with a mocked apply).
- Firewall posture: allowlist, IDPS/threat intelligence blocking, zone redundancy.

## Cost note

Firewalls and NAT gateways are the dominant fixed costs: roughly hundreds of USD per month per AZ or firewall before data processing. For non-production, share one hub or use a single AZ.

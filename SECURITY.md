# Security reporting

Do not disclose exploitable vulnerabilities, tokens or private deployment details
in public issues. Use GitHub private vulnerability reporting when available on
this repository's Security tab. If it is unavailable, open an issue requesting a
private contact channel without including vulnerability details.

Only the latest published 0.1.x release is intended to receive fixes; no response
SLA is offered. Include the plugin revision, APISIX version, a minimal sanitized
configuration, expected behavior and reproduction steps in the private report.

Public routes must enforce authentication and intended audiences. The internal
bridge requires a loopback peer and an expiring one-use ticket. Consult README.md
for the complete trust boundary and deployment requirements.

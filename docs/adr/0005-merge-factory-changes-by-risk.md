# Merge factory changes by risk

Factory changes merge without a human unless they fall in a small human-reviewed set: breaking public API, authentication/TLS/credentials, new dependencies, factory controls, and releases. Changed paths and an API diff decide the class, never an agent's judgment. Riskier automatic classes require full E2E, an API diff, and a second independent review.

The maintainer chose to enable every automatic class from launch rather than earn autonomy in stages. The launch checks, pause rules, and kill switch in [the factory policy](../factory.md) are therefore the main protection against a bad start.

### 2026-09-18: Use a bounded Azure fill starting preset
**By:** Performance
**What:** The Azure helper generates and displays cluster fill settings from one option table: 1 process, 2 connections per primary, 512-byte keys and values, and a 1,024-command pipeline. Documentation treats this as a safe tuning starting point, not an optimal default or throughput guarantee.
**Why:** The previous displayed 6 connections contradicted the executed 2, while its 8-process, 256 KiB-value, 8,192-command preset exceeded the fill worker or estimated-memory guardrails. The replacement matches the bounded workload measured for #76 and keeps concurrency and memory tradeoffs explicit until #81 provides Azure-specific benchmark evidence.

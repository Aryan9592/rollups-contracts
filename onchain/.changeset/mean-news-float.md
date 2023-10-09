---
"@cartesi/rollups": major
---

Inputs are now blockchain-agnostic and self-contained blobs. For example, inputs added by EVM contracts like `InputBox` are encoded using `abi.encodeWithSignature` and contain EVM-specific metadata like `msg.sender` and `block.timestamp`.

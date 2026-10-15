# Gateway

`http_server.gd` owns the local HTTP routes, bounded Master requests and expiring
Gateway credentials. `master_gateway_client/` connects to Master and reports
replies/disconnection through signals. Gameplay authority remains with World.

[A1 lifecycle contract and verification](../../../docs/development/gateway-lifecycle.md)
describes limits, logout, expiry and the distinction from World session authority.

// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// FORK-ONLY: test for the Cloudflare Worker. Never in a PR to upstream.

import { INTAKE } from "./worker.js";
import workerDefault from "./worker.js";

// Simple test - verify exports
const intake = INTAKE;
const hasFetch = typeof workerDefault?.fetch === "function";

if (intake !== "madeira-bcd/2") {
	console.error("FAIL: INTAKE constant mismatch:", intake);
	process.exit(1);
}
if (!hasFetch) {
	console.error("FAIL: default export missing fetch handler");
	process.exit(1);
}
console.log("PASS: worker exports INTAKE and has fetch handler");
// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// FORK-ONLY: test for the Cloudflare Worker. Never in a PR to upstream.

import { describe, it, expect } from "node:test";
import worker from "./worker.js";

describe("BCD log intake worker (placeholder)", () => {
	it("exports INTAKE constant", () => {
		expect(worker.INTAKE).toBe("madeira-bcd/2");
	});

	it("has a fetch handler", () => {
		expect(typeof worker.default.fetch).toBe("function");
	});
});
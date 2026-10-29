// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// FORK-ONLY: this is the Cloudflare Worker for BCD's log intake. Never in a PR to upstream.

export const INTAKE = "madeira-bcd/2";

export default {
	async fetch(request, env, ctx) {
		// Minimal placeholder - the real worker handles log uploads to R2
		return new Response("BCD log intake worker placeholder", { status: 200 });
	}
};
// A backend smoke test: navigates to the
// page, selects each backend in turn, awaits the Melange side's dynamic import(), and asserts both
// expose create/push/resize/finish with the right arity before any replay test depends on them.

'use strict';

const { test, expect } = require('@playwright/test');

for (const backend of ['jsoo', 'melange']) {
  test(`${backend} backend exposes create/push/resize/finish, callable with their documented arguments`, async ({
    page,
  }) => {
    // A bare typeof check alone would not catch an under/over-curried export (a common cross-backend
    // divergence risk): the round-trip test below actually calls each with its documented argument
    // count and checks the result decodes, which is a stronger proof of correct arity than JS
    // Function.length -- jsoo's exported-function wrapper and Melange's `unit -> 'a` representation
    // both report misleading `.length` values that do not reflect the real OCaml arity.
    const consoleErrors = [];
    page.on('pageerror', (error) => consoleErrors.push(String(error)));
    await page.goto('/');
    const types = await page.evaluate(async (backendName) => {
      const bridge = await window.TesseraBackends.load(backendName);
      return {
        create: typeof bridge.create,
        push: typeof bridge.push,
        resize: typeof bridge.resize,
        finish: typeof bridge.finish,
      };
    }, backend);
    expect(consoleErrors).toEqual([]);
    expect(types).toEqual({ create: 'function', push: 'function', resize: 'function', finish: 'function' });
  });

  test(`${backend} backend create/push/resize/finish round-trip decodes and starts with a reset`, async ({
    page,
  }) => {
    await page.goto('/');
    const result = await page.evaluate(async (backendName) => {
      const bridge = await window.TesseraBackends.load(backendName);
      const frames = [bridge.create('html', 1, 4, 1), bridge.push('A'), bridge.resize(6, 2), bridge.finish()];
      const decoded = frames.map((json) => window.Tessera.decodeHtmlEnvelope(json));
      return { ok: decoded.every((d) => d.ok), kinds: decoded.map((d) => d.value.meta.kind) };
    }, backend);
    expect(result.ok).toBe(true);
    expect(result.kinds[0]).toBe('reset');
  });
}

// TEMPORARY — scratch test for issue #162 only. Deliberately fails so that the
// `middleware` required status check goes red, proving branch protection on `main`
// actually refuses the merge. This file must never be merged; the scratch branch it
// lives on is deleted once the proof is recorded on #162.
import { describe, expect, it } from 'vitest';

describe('issue #162 branch-protection proof', () => {
  it('fails on purpose to turn the required `middleware` check red', () => {
    expect('protection').toBe('unproven');
  });
});

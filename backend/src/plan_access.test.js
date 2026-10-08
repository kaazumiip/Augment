const test = require('node:test');
const assert = require('node:assert/strict');
const { activePlan, generationUsage, validRedeemCode } = require('./plan_access');

const september = Date.UTC(2026, 8, 30, 12);

test('free and plus limits count successful generations in the current month', () => {
  const usage = [{ userId: 'a', month: '2026-09', count: 1, bandCount: 1 },
    { userId: 'a', month: '2026-08', count: 50 }];
  const free = generationUsage({ userId: 'a', usage, now: september });
  assert.equal(free.limit, 2);
  assert.equal(free.remaining, 1);
  assert.equal(free.bandUsed, 1);
  assert.equal(free.resetsAt, '2026-10-01T00:00:00.000Z');
  const plus = generationUsage({ userId: 'a', usage, now: september,
    subscription: { plan: 'plus', currentPeriodEnd: '2026-10-15T00:00:00Z' } });
  assert.equal(plus.limit, 18);
  assert.equal(plus.remaining, 17);
  assert.equal(plus.bandUsed, 1);
});

test('permanent redeemed Pro has 55 generation limit', () => {
  const subscription = { plan: 'pro', source: 'redeem', permanent: true };
  assert.equal(activePlan(subscription, Date.UTC(2035, 0, 1)), 'pro');
  const usage = generationUsage({ userId: 'a', subscription, usage: [], now: september });
  assert.equal(usage.limit, 55);
  assert.equal(usage.remaining, 55);
});

test('expired paid plans return to Free allowance', () => {
  assert.equal(activePlan({ plan: 'plus', currentPeriodEnd: '2026-09-01T00:00:00Z' }, september), 'free');
});

test('redeem code is exact after trimming whitespace', () => {
  assert.equal(validRedeemCode(' AugmentVip '), true);
  assert.equal(validRedeemCode('augmentvip'), false);
  assert.equal(validRedeemCode('wrong'), false);
});

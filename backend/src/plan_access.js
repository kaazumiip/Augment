const crypto = require('crypto');

const GENERATION_LIMITS = Object.freeze({ free: 3, plus: 25, pro: null });

function currentMonth(now = Date.now()) {
  return new Date(now).toISOString().slice(0, 7);
}

function activePlan(subscription, now = Date.now()) {
  if (!subscription) return 'free';
  if (subscription.source === 'redeem' && subscription.permanent === true &&
      subscription.plan === 'pro') return 'pro';
  const ends = Date.parse(subscription.gracePeriodEnd || subscription.currentPeriodEnd);
  return Number.isFinite(ends) && now <= ends &&
    Object.prototype.hasOwnProperty.call(GENERATION_LIMITS, subscription.plan)
    ? subscription.plan : 'free';
}

function generationUsage({ userId, subscription, usage, reservations = 0, now = Date.now() }) {
  const plan = activePlan(subscription, now);
  const limit = GENERATION_LIMITS[plan];
  const month = currentMonth(now);
  const used = usage.filter((item) => item.userId === userId && item.month === month)
    .reduce((total, item) => total + Math.max(0, Number(item.count) || 0), 0);
  return {
    plan, month, used, limit, inProgress: reservations,
    remaining: limit === null ? null : Math.max(0, limit - used - reservations),
    resetsAt: new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5)), 1)).toISOString(),
  };
}

function validRedeemCode(supplied, configured = 'AugmentVip') {
  if (typeof supplied !== 'string' || supplied.length > 64) return false;
  const candidate = crypto.createHash('sha256').update(supplied.trim()).digest();
  const expected = crypto.createHash('sha256').update(configured).digest();
  return crypto.timingSafeEqual(candidate, expected);
}

module.exports = {
  GENERATION_LIMITS,
  activePlan, currentMonth, generationUsage, validRedeemCode,
};

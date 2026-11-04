function greeting(name) {
  const n = (name ?? 'world').toString().trim();
  if (n.length === 0) return { ok: true, message: 'Hello, world!' };
  if (n.length > 30) return { ok: false, error: 'name too long (max 30)' };
  if (!/^[\p{L}\p{N} _-]+$/u.test(n)) return { ok: false, error: 'invalid characters' };
  return { ok: true, message: `Hello, ${n}!` };
}
module.exports = { greeting };

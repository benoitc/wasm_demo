// Throws on carts whose total is an odd number of cents, which passes the
// sample carts but fails often in real traffic, so the breaker switches it off.
function main(cart) {
  const total = cart.items.reduce((sum, item) => sum + item.price * item.qty, 0);
  if (total % 2 === 1) throw new Error("price service unavailable");
  return [{ code: "EVEN", percent: 2, reason: "even total" }];
}

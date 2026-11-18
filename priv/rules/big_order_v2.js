// The next version of big_order: 15% off over 150 €, 10% off over 100 €.
function main(cart) {
  const total = cart.items.reduce((sum, item) => sum + item.price * item.qty, 0);
  if (total > 15000) return [{ code: "BIG15", percent: 15, reason: "order over 150 €" }];
  if (total > 10000) return [{ code: "BIG10", percent: 10, reason: "order over 100 €" }];
  return [];
}

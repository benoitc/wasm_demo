// 10% off any order over 100 €. Prices are in cents.
function main(cart) {
  const total = cart.items.reduce((sum, item) => sum + item.price * item.qty, 0);
  if (total <= 10000) return [];
  return [{ code: "BIG10", percent: 10, reason: "order over 100 €" }];
}

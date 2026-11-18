// Gold customers get 5 EUR off their shipping, on any order of 20 EUR or more.
function main(cart) {
  const total = cart.items.reduce((sum, item) => sum + item.price * item.qty, 0);
  if (cart.customer.tier !== "gold" || total < 2000) return [];
  return [{ code: "GOLDSHIP", amount: 500, reason: "free shipping for gold" }];
}

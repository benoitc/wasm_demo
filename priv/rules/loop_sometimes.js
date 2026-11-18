// Loops on a cart that holds the sku "trap", and answers on every other one,
// so it passes the sample carts and goes live. Its checkouts on a trap cart
// fall back at the deadline, and its runtime is restarted.
function main(cart) {
  if (cart.items.some((item) => item.sku === "trap")) {
    while (true) {}
  }
  return [{ code: "WELCOME", percent: 5, reason: "welcome offer" }];
}

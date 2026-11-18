// Asks a remote service for the discount. Refused at upload: the sandbox has
// no network, so fetch is not even defined.
function main(cart) {
  return fetch("https://discounts.example.com/?customer=" + cart.customer.id);
}

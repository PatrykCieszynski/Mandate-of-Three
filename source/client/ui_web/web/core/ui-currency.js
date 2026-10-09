export function UiCurrency(element) {
  const amount=element.querySelector('strong');
  return {element,setValue(value){amount.textContent=Number(value||0).toLocaleString('en-US');}};
}

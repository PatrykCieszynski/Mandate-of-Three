// Selectors refer to markup owned by these modules; fail explicitly if it is missing.
export function element<K extends keyof HTMLElementTagNameMap>(root: ParentNode, selector: string, tag: K): HTMLElementTagNameMap[K] {
  const result = root.querySelector<HTMLElementTagNameMap[K]>(selector);
  if (!result || result.localName !== tag) throw new Error('Missing UI element: ' + selector);
  return result;
}

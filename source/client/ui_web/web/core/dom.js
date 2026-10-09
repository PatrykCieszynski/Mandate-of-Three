// Selectors refer to markup owned by these modules; fail explicitly if it is missing.
export function element(root, selector, tag) {
    const result = root.querySelector(selector);
    if (!result || result.localName !== tag)
        throw new Error('Missing UI element: ' + selector);
    return result;
}

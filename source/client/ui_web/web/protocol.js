export const VERSION = 1;
export const MAX_BYTES = 16384;
const bytes = value => new TextEncoder().encode(value).length;
export function encode(type, payload = {}, id) {
  const message = {v: VERSION, type, payload};
  if (id !== undefined) message.id = id;
  const json = JSON.stringify(message);
  decode(json);
  return json;
}
export function decode(json) {
  if (typeof json !== 'string' || bytes(json) > MAX_BYTES) throw Error('size');
  const value = JSON.parse(json);
  if (!value || Array.isArray(value) || typeof value !== 'object' ||
      Object.keys(value).some(key => !['v','type','id','payload'].includes(key)) ||
      value.v !== VERSION || typeof value.type !== 'string' ||
      !value.payload || typeof value.payload !== 'object' || Array.isArray(value.payload) ||
      ('id' in value && (typeof value.id !== 'string' || !value.id.length || value.id.length > 80))) throw Error('envelope');
  return value;
}

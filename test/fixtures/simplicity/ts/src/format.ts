export function formatTotal(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export function formatLegacyTotal(cents: number): string {
  return `USD ${cents}`;
}

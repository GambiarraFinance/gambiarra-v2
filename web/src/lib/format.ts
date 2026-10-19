const THOUSANDS = /\B(?=(\d{3})+(?!\d))/g;

const SUPERSCRIPT: Record<string, string> = {
  "0": "⁰",
  "1": "¹",
  "2": "²",
  "3": "³",
  "4": "⁴",
  "5": "⁵",
  "6": "⁶",
  "7": "⁷",
  "8": "⁸",
  "9": "⁹",
  "-": "⁻",
};

/** 2560000000 → "2.560.000.000" (pt-BR grouping, no decimals). */
export function formatIntegerPtBr(value: bigint): string {
  const negative = value < 0n;
  const digits = (negative ? -value : value).toString();
  return `${negative ? "-" : ""}${digits.replace(THOUSANDS, ".")}`;
}

function decimalParts(value: bigint, decimals: number): { negative: boolean; whole: string; fraction: string } {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = (abs % base).toString().padStart(decimals, "0");
  return { negative, whole: whole.toString(), fraction };
}

/**
 * Formats a token amount with pt-BR separators and *rounds half-up* to
 * `maxFractionDigits`. All math stays in bigint, so 18-decimal amounts never
 * pass through a lossy JS number.
 *
 * 3e18 / 18 → "3"; 1234567890000000000 / 18 → "1,2346".
 */
export function formatTokenAmount(value: bigint, decimals: number, maxFractionDigits = 4): string {
  const safeDecimals = Math.max(0, Math.trunc(decimals));
  const digits = Math.max(0, Math.trunc(maxFractionDigits));
  const { negative, whole, fraction } = decimalParts(value, safeDecimals);
  const sign = negative ? "-" : "";

  if (safeDecimals === 0) {
    return `${sign}${formatIntegerPtBr(BigInt(whole))}`;
  }

  if (digits === 0) {
    const base = 10n ** BigInt(safeDecimals);
    const remainder = BigInt(fraction);
    const rounded = BigInt(whole) + (remainder * 2n >= base ? 1n : 0n);
    if (rounded === 0n && value !== 0n) return "<1";
    return `${sign}${formatIntegerPtBr(rounded)}`;
  }

  const keep = Math.min(digits, safeDecimals);
  const scale = 10n ** BigInt(safeDecimals - keep);
  let scaled = BigInt(fraction) / scale;
  const remainder = BigInt(fraction) % scale;

  if (remainder * 2n >= scale) scaled += 1n;

  let wholeValue = BigInt(whole);
  const overflow = 10n ** BigInt(keep);
  if (scaled >= overflow) {
    wholeValue += 1n;
    scaled -= overflow;
  }

  if (wholeValue === 0n && scaled === 0n && value !== 0n) {
    return `${sign}<0,${"0".repeat(keep - 1)}1`;
  }

  const fractionStr = scaled.toString().padStart(keep, "0").replace(/0+$/, "");
  return fractionStr.length > 0
    ? `${sign}${formatIntegerPtBr(wholeValue)},${fractionStr}`
    : `${sign}${formatIntegerPtBr(wholeValue)}`;
}

const COMPACT_UNITS = [
  { exponent: 0, suffix: "" },
  { exponent: 3, suffix: " mil" },
  { exponent: 6, suffix: " mi" },
  { exponent: 9, suffix: " bi" },
  { exponent: 12, suffix: " tri" },
] as const;

function roundScaled(value: bigint, decimals: number, exponent: number, fractionDigits: number): bigint {
  const numerator = value * 10n ** BigInt(fractionDigits);
  const denominator = 10n ** BigInt(decimals + exponent);
  const quotient = numerator / denominator;
  const remainder = numerator % denominator;
  return remainder * 2n >= denominator ? quotient + 1n : quotient;
}

function scaledToString(scaled: bigint, fractionDigits: number): string {
  if (fractionDigits === 0) return scaled.toString();
  const digits = scaled.toString().padStart(fractionDigits + 1, "0");
  const whole = digits.slice(0, -fractionDigits);
  const fraction = digits.slice(-fractionDigits).replace(/0+$/, "");
  return fraction.length > 0 ? `${whole},${fraction}` : whole;
}

/**
 * Compact, pt-BR form for on-chain totals: 2190000000000000000000000000 / 18
 * → "2,19 bi". Uses bigint only; no `Number(value)` precision loss.
 */
export function formatCompactToken(value: bigint, decimals: number, maxFractionDigits = 2): string {
  const safeDecimals = Math.max(0, Math.trunc(decimals));
  const digits = Math.max(0, Math.trunc(maxFractionDigits));
  const { negative, whole } = decimalParts(value, safeDecimals);
  const sign = negative ? "-" : "";
  const absolute = negative ? -value : value;
  const size = whole.length;

  if (size <= 3) {
    return `${sign}${formatTokenAmount(absolute, safeDecimals, digits)}`;
  }

  let unitIndex = Math.min(Math.floor((size - 1) / 3), COMPACT_UNITS.length - 1);
  let unit = COMPACT_UNITS[unitIndex];
  let scaled = roundScaled(absolute, safeDecimals, unit.exponent, digits);

  // 999,999 mi rounds to 1000 mi — promote to the next unit instead.
  if (scaled >= 10n ** BigInt(digits + 3) && unitIndex < COMPACT_UNITS.length - 1) {
    unitIndex += 1;
    unit = COMPACT_UNITS[unitIndex];
    scaled = roundScaled(absolute, safeDecimals, unit.exponent, digits);
  }

  if (unitIndex === COMPACT_UNITS.length - 1 && scaled >= 10n ** BigInt(digits + 3)) {
    return `${sign}${formatScientific(absolute, digits + 1)}`;
  }

  return `${sign}${scaledToString(scaled, digits)}${unit.suffix}`;
}

function superscript(value: number): string {
  return value
    .toString()
    .split("")
    .map((char) => SUPERSCRIPT[char] ?? char)
    .join("");
}

/**
 * Exact bigint scientific notation with pt-BR mantissa:
 * 2560000000000000000000000000000 → "2,56 × 10³⁰".
 */
export function formatScientific(value: bigint, significantDigits = 3): string {
  const negative = value < 0n;
  const digitsOnly = (negative ? -value : value).toString();
  const significant = Math.max(1, Math.trunc(significantDigits));

  if (digitsOnly === "0") return "0";

  let mantissaDigits = digitsOnly.slice(0, significant);
  let exponent = digitsOnly.length - 1;

  if (digitsOnly.length > significant && Number(digitsOnly[significant]) >= 5) {
    let rounded = (BigInt(mantissaDigits) + 1n).toString();
    if (rounded.length > significant) {
      rounded = rounded.slice(0, significant);
      exponent += 1;
    }
    mantissaDigits = rounded;
  }

  const whole = mantissaDigits.slice(0, 1);
  const fraction = mantissaDigits.slice(1).replace(/0+$/, "");
  const mantissa = fraction.length > 0 ? `${whole},${fraction}` : whole;

  return `${negative ? "-" : ""}${mantissa} × 10${superscript(exponent)}`;
}

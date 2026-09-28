/**
 * The Tenax mark: two halves of a T held together by a clasp. Drawn as three paths so the halves and the clasp can
 * take different colours in the light and dark themes.
 */
export const MARK_VIEWBOX = "-4 -4 621 491";
export const MARK_LEFT =
  "M288.0 483.0L237.0 483.1L228.0 481.5L221.0 477.2L210.6 467.0L200.0 455.0L196.8 449.0L195.6 442.0L195.6 250.0L191.2 239.0L175.7 223.0L170.4 213.0L169.1 205.0L169.0 162.0L168.2 157.0L165.7 152.0L159.0 145.5L151.0 143.0L23.0 142.4L13.0 138.2L7.6 134.0L3.6 129.0L0.7 122.0L-0.4 114.0L-0.4 28.0L0.6 22.0L3.7 15.0L12.0 6.0L20.5 2.0L28.0 0.9L278.0 0.8L286.0 2.8L290.0 5.7L293.3 10.0L295.2 21.0L295.2 58.0L293.8 63.0L287.8 69.0L218.7 125.0L213.8 133.0L212.3 141.0L213.5 150.0L218.8 159.0L286.8 216.0L292.0 221.0L294.4 225.0L294.8 473.0L293.0 480.0Z";
export const MARK_RIGHT =
  "M402.0 483.0L324.0 483.0L319.0 480.1L317.2 476.0L316.9 221.0L316.3 217.0L313.1 211.0L291.0 191.6L289.3 189.0L289.0 186.0L292.0 180.6L388.0 105.3L392.5 99.0L393.4 94.0L392.2 87.0L389.0 82.6L319.4 22.0L317.5 18.0L318.8 10.0L321.3 6.0L325.0 2.9L335.0 0.2L577.0 -0.1L589.0 0.7L595.0 2.8L602.0 7.0L607.4 13.0L610.8 20.0L612.3 27.0L612.5 115.0L610.3 125.0L605.0 132.9L597.0 139.2L585.0 142.7L461.0 142.9L451.2 147.0L446.4 152.0L444.1 156.0L442.7 166.0L442.5 445.0L441.2 450.0L438.3 455.0L417.0 477.2L410.0 481.4Z";
export const MARK_CLASP =
  "M271.0 170.3L265.0 170.1L237.0 146.6L235.4 144.0L235.2 141.0L237.2 137.0L329.0 64.2L335.0 64.4L365.2 90.0L366.1 94.0L364.5 97.0Z";

export function Mark({ className, title }: { className?: string; title?: string }) {
  return (
    <svg
      className={`mark${className ? ` ${className}` : ""}`}
      viewBox={MARK_VIEWBOX}
      role={title ? "img" : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
    >
      <path className="mark-left" d={MARK_LEFT} />
      <path className="mark-right" d={MARK_RIGHT} />
      <path className="mark-clasp" d={MARK_CLASP} />
    </svg>
  );
}

export function Logo() {
  return (
    <span className="logo">
      <Mark />
      <span className="logo-word">Tenax</span>
    </span>
  );
}

/// Spoken routing prefix — IDEAS.md §2.
///
/// Saying the destination in the first two seconds is the only routing model
/// compatible with a one-press trigger: any UI picker reintroduces a decision,
/// a screen and a tap. The prefix is stripped from the stored note but kept as
/// metadata.
///
/// This lives on the server rather than in the app so improving the parser is a
/// deploy rather than an App Store review.

/// Longest first, so "trade observation" is not shadowed by a future "trade".
const ROUTES = ["investment idea", "trade observation", "follow up"] as const;

/// Whisper-class models punctuate a spoken pause as a dash, comma or colon, and
/// which one you get for the same utterance is not stable. Accept any of them.
const SEPARATOR = /^[\s]*[—–\-:,][\s]*/;

export interface Routed {
  route: string | null;
  body: string;
}

export function parseRoute(transcript: string): Routed {
  const trimmed = transcript.trim();
  const lowered = trimmed.toLowerCase();

  for (const route of ROUTES) {
    if (!lowered.startsWith(route)) continue;

    const remainder = trimmed.slice(route.length);
    const separator = remainder.match(SEPARATOR);
    // Require a separator so "follow up on that later" — a sentence that merely
    // opens with the words — is not mistaken for a routed memo.
    if (!separator) continue;

    return { route, body: remainder.slice(separator[0].length).trim() };
  }

  return { route: null, body: trimmed };
}

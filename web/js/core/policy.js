// Which content may appear (port of ContentPolicy, Sources/LuluCore/ContentPolicy.swift).

const MODES = ["solo", "couple", "friend"];

/** Effective mode: solo when I am solo; friend when either side is a friend; else couple. Unknown partner mode follows mine. */
export function effectiveMode(myMode, partnerMode) {
  const mine = MODES.includes(myMode) ? myMode : "couple";
  const theirs = MODES.includes(partnerMode) ? partnerMode : null;
  if (mine === "solo") return "solo";
  if (mine === "friend" || theirs === "friend") return "friend";
  return "couple";
}

/** Kisses, hugs and the like (intimate stickers): couple only. */
export function allowsIntimate(myMode, partnerMode) {
  return effectiveMode(myMode, partnerMode) === "couple";
}

/** Partner's character: presence → their latest message → the seat's namesake. */
export function partnerCharacter(partnerSeat, presence, lastMessageCharacter) {
  return presence?.character ?? lastMessageCharacter ?? partnerSeat;
}

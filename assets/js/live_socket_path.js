/**
 * Which LiveView socket a page connects to.
 *
 * `/live` verifies the session cookie; `/embed-live` needs none, because an
 * embedded booking page authenticates with the signed embed token in its
 * LiveView session instead (mobile browsers withhold SameSite=Lax cookies
 * from cross-site iframes).
 *
 * A page the server rendered as an embed carries `data-embed-served` on
 * `<html>` and was sent without writing a session cookie, so it never uses
 * `/live`, where it would find no session and reload for ever. Unframed, it
 * normally never connects at all (see `topLevelEmbedRedirect`); the marker
 * here only keeps the socket choice right should it ever do so.
 */
export function liveSocketPath(win = window) {
  const framed = win.self !== win.top
  const servedAsEmbed = win.document.documentElement.hasAttribute("data-embed-served")

  return framed || servedAsEmbed ? "/embed-live" : "/live"
}

// The query parameters that make the server serve a page as an embed.
const EMBED_PARAMS = ["embed", "parent-origin"]

/**
 * Where an embed page opened in its own tab should go instead, or `null`.
 *
 * A browser that sends no `Sec-Fetch-Dest` (plain HTTP, Safari before 16.4)
 * gets the embed rendering even for a top-level visit, and the server cannot
 * tell that visit from a frame. Connected as an embed, the unframed page
 * would either be held to the embed allowlist and land on the
 * embed-unavailable notice, or render as if framed. The page itself knows it
 * is not framed, so it replaces itself with the same URL minus the embed
 * parameters: an ordinary page, with a session. That URL carries no
 * `embed=1`, so the server marks nothing and this cannot loop.
 */
export function topLevelEmbedRedirect(win = window) {
  const framed = win.self !== win.top
  const servedAsEmbed = win.document.documentElement.hasAttribute("data-embed-served")

  if (framed || !servedAsEmbed) return null

  const url = new URL(win.location.href)
  EMBED_PARAMS.forEach(param => url.searchParams.delete(param))
  return url.toString()
}

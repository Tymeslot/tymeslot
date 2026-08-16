defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteEtag do
  @moduledoc """
  Reads the version marker a provider stamped on a placeholder it has just
  written, out of whatever shape that write answered with.

  This is the value `CalendarSyncMirrorSchema`'s `target_etag` holds, and it is
  the single thing the three etag-based conflict kinds turn on. Without it
  `mirror_edited`, `both_changed` and `delete_race` cannot fire at all — they
  each need a baseline describing the placeholder *as written* to compare the
  target's cached copy against, and there is no other place that baseline can
  come from.

  ## Why the write response, and not the cache

  The obvious alternative is to read the etag back from
  `provider_calendar_events` after writing. It is wrong, and the way it is wrong
  is quiet: that row holds whatever the target's last *inbound* sync fetched,
  which is the placeholder as it was **before** this write. Stamping that as the
  baseline means the next pass compares our own change against a pre-change
  value, finds them different and finds the provider's stamp later than ours,
  and files the engine's own write as a stranger's edit — a false row per write
  per series. The log is read when somebody is trying to work out why a calendar
  looks wrong, so a history that is mostly the engine reporting itself is worth
  less than an empty one.

  Timestamps do not close it either. Our write stamps `last_synced_at`; the
  provider stamps `provider_updated_at` when it applies that same write,
  necessarily later. "Changed after our write" is therefore true of our own
  write as much as of anybody else's.

  The write response is the only source that describes the placeholder *after*
  the write, at the moment of the write, without a further round trip.

  ## Why this reads shapes rather than providers

  Nothing here asks which provider answered, for the same reason
  `SyncLink.ProviderEventId` does not: the write path crosses three layers that
  each describe an event differently, and a `case` on provider would have to be
  kept in step with all of them. A raw OAuth body is string-keyed with `etag`
  (Google) or `@odata.etag` (Microsoft Graph); a converted event, if it carries
  one at all, is atom-keyed. A provider that starts reporting an etag in a shape
  already listed here is handled without a change.

  The string key wins over the atom key when a map somehow carries both: the raw
  body is the provider's own account of the write, whereas an atom-keyed etag on
  the same map came from converting an earlier *read*, and describes the event
  before this write rather than after it.

  ## Why absence is `nil`, and what that switches off

  Not every provider reports one. Outlook's write response is narrowed by
  `convert_event/1` before it reaches here, and the CalDAV family answers a bare
  `:ok` from a PUT whose response ETag the HTTP layer does not surface. Both
  record `nil`.

  `nil` is a *stated* rule rather than an accident: it means "no baseline", and
  `ConflictLog.mirror_edited?/2` requires two binary etags to compare, so the
  three etag-based kinds are simply off for such a provider. `write_failed` and
  `occurrence_moved` are unaffected and keep firing everywhere. Under-reporting
  for a provider that cannot supply the evidence is the correct trade against
  inventing a baseline it never gave us — a placeholder value would compare
  unequal to every real etag and turn every pass into a conflict.

  An empty or blank etag is treated as absent for the same reason. A provider
  sending `""` has reported nothing, and storing the empty string would be a
  baseline no real value can ever match.

  ## Normalisation

  Quotes are stripped by delegating to `CalDAV.EventProcessor.clean_etag/1`,
  because the value's only job is to compare equal to the cache's `etag` column
  and the inbound sync populates that through the very same function. Google
  sends the etag as an HTTP entity tag — `"\\"3573625707763998\\""`, quotes
  included — so storing the raw form would make a matching pair compare unequal,
  which is the same false-positive flood by another route.

  Delegating rather than reimplementing is the point. `clean_etag/1` trims
  quotes from both ends, which on a weak tag like Graph's `W/"abc123"` strips
  the trailing quote and leaves the inner one — an untidy result that is
  nonetheless the *right* one here, because the other side of every comparison
  is untidy in exactly the same way. Normalising more carefully on this side
  alone would make a matching pair compare unequal. The two sides have to agree
  more than either has to be tidy, and one shared function is what guarantees
  they cannot drift.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor

  @doc """
  The etag a landed write reported, or `nil` when it reported none.

  Takes the write result itself, so a caller need not know whether its provider
  answered `:ok`, `{:ok, raw_body}` or `{:ok, converted_event}`.
  """
  @spec extract(term()) :: String.t() | nil
  def extract({:ok, written}), do: extract(written)
  def extract(%{"etag" => etag}), do: normalise(etag)
  def extract(%{"@odata.etag" => etag}), do: normalise(etag)
  def extract(%{etag: etag}), do: normalise(etag)
  def extract(_no_etag), do: nil

  # `clean_etag/1` already answers `nil` for a non-binary, so the only thing
  # left to decide is that a value cleaned down to nothing is nothing.
  defp normalise(etag) do
    case EventProcessor.clean_etag(etag) do
      cleaned when is_binary(cleaned) -> blank_to_nil(String.trim(cleaned))
      _not_a_binary -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(etag), do: etag
end

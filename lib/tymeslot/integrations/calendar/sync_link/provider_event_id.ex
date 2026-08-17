defmodule Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId do
  @moduledoc """
  Reads the identifier a provider filed a placeholder under, out of whatever
  shape that provider answered with.

  The mapping row's `target_provider_event_id` is the only handle teardown and
  the reconcile sweep have on a placeholder, and loop prevention matches cached
  events against it. An id read wrongly here is therefore not a cosmetic
  defect: it produces a mapping that addresses an event no provider holds.

  ## Why the shapes differ

  There is no single response shape to match, because the layers below answer in
  three different vocabularies and all three reach this module.

  A create pipes the provider's response through its `convert_event/1`, which
  for the OAuth families lands the provider's own event id under `uid` and emits
  no `provider_event_id` key at all. A raw provider body arrives string-keyed,
  under `"id"`. A caller that already knows the id passes it explicitly. Reading
  only one of those is how 420 live mirror rows came to record no provider id
  while claiming to be active — and a placeholder with no recorded id cannot be
  deleted by any path.

  ## The two success shapes

  `update_event/3` answers a bare `:ok` from the CalDAV family, which keeps the
  uid it was handed, and `{:ok, event}` from the OAuth families, which pipe the
  response through their `convert_event/1`. Both mean the write landed, and
  `for_update/2` below is what turns either into the id to record — the bare
  `:ok` carrying no id of its own, so the uid the write was addressed to is the
  answer.

  `wrote?/1` states that pair once, for every caller that only needs to know
  whether the write landed. It lives here rather than in each of them because
  a caller that writes the match out itself sees only the shape its own
  provider happens to answer with: the mirror colour patch matched the bare
  `:ok` alone and logged every successful Google patch — the one provider that
  reaches that path at all — as a failure.

  ## Why an update needs its own entry point

  `for_update/2` exists because the two provider families disagree about what an
  update tells you. Google hashes the UID it is handed and stores the event under
  that digest, answering with the event so the id arrives under `uid`. The CalDAV
  family stores the UID unchanged and answers a bare `:ok`, so the UID the caller
  already holds *is* the identifier.

  Collapsing the two — recording the UID we asked for in both cases — wrote an
  identifier Google does not know onto every mapping made through the 409
  create→update fallback. Loop prevention could not then recognise the
  placeholder when it returned in the cache, so it was mirrored again and a real
  event grew a fresh "Busy" block on every sweep.

  Reading the id off the response rather than deriving it is what keeps this
  provider-agnostic: no provider-specific mapper is called from here, and a
  provider that files events under an id of its own choosing is handled by the
  same clause as Google.

  ## Why the identity a placeholder is *cached* under lives here too

  Recording the id is only half the problem. The other half is finding the
  placeholder again in `provider_calendar_events`, and the id the write answered
  with is not what the target's next inbound sync files it under: Google's
  normaliser caches `raw["iCalUID"] || raw["id"]` (`event_normaliser.ex:65`), and
  Google's iCalUID is the event id with `@google.com` appended. The CalDAV family
  keeps the caller's UID unchanged, so for it the two are the same string.

  Both identities therefore have to be tried, and `cache_identities/2` states
  that once. It was stated twice before — loop prevention expanded them in
  `CalendarSyncMirrorQueries` while `SyncLink.ConflictLog` looked up `target_uid`
  alone — and the half that did not expand found nothing at all: 105 of 105 live
  mirror rows were unresolvable that way, which switched every etag-based
  conflict kind off for a Google target while the suite stayed green.
  """

  @google_domain "@google.com"

  @doc """
  Whether an `update_event/3` or `create_event/2` result says the write landed.

  Both success shapes and nothing else — see "The two success shapes" above.
  A guard so it can head a `case` clause, which is where every caller needs it.
  """
  defguard wrote?(result) when result == :ok or (is_tuple(result) and elem(result, 0) == :ok)

  @doc """
  The provider's id for an event, or `nil` when the shape carries none.

  Ordered most specific first: an explicit `provider_event_id` always wins,
  because a caller that names it means it. `uid` is consulted last, since it is
  the id only when nothing more precise was offered.
  """
  @spec extract(term()) :: String.t() | nil
  def extract(%{provider_event_id: id}) when is_binary(id), do: id
  def extract(%{"id" => id}) when is_binary(id), do: id
  def extract(%{id: id}) when is_binary(id), do: id
  def extract(%{uid: id}) when is_binary(id), do: id
  def extract(_other), do: nil

  @doc """
  The id an update filed the event under, given the update's result and the UID
  the write was addressed to.

  A bare `:ok` is the provider returning nothing to read, which is the CalDAV
  family keeping the UID it was given. A response yielding no id falls back to
  the same answer rather than to `nil`: a mapping with no id addresses nothing,
  whereas the UID the write used is at worst the identifier already believed.
  """
  @spec for_update(:ok | {:ok, term()}, String.t()) :: String.t()
  def for_update(:ok, target_uid), do: target_uid
  def for_update({:ok, updated}, target_uid), do: extract(updated) || target_uid

  @doc """
  Every uid a placeholder could be cached under, given the UID the write was
  addressed to and the id the provider answered with.

  Ordered by how likely each is to be the row that exists, so a caller looking
  the identities up one at a time stops at the first hit: the provider's own id
  suffixed with Google's domain comes first because that is the form every live
  Google placeholder is cached under, then the bare id, then the UID we asked
  for, which is the CalDAV family's answer.

  `nil` on either side is dropped rather than carried — an identity of `nil`
  matches every cached row whose uid is also absent — and an identifier that
  already carries the domain gains no second copy of it. Duplicates are removed,
  so a CalDAV mapping where the two columns hold the same string yields two
  candidates rather than four.
  """
  @spec cache_identities(String.t() | nil, String.t() | nil) :: [String.t()]
  def cache_identities(target_uid, provider_event_id) do
    [provider_event_id, target_uid]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&google_variants/1)
    |> Enum.uniq()
  end

  # An identifier that already carries the domain is left alone; anything else
  # gains the suffixed form ahead of the bare one. Both go in because a target is
  # Google or it is not, and the caller asks the same question either way — a
  # CalDAV uid with `@google.com` appended matches nothing, which costs one
  # lookup or one set entry and no correctness.
  defp google_variants(identifier) do
    if String.ends_with?(identifier, @google_domain) do
      [identifier]
    else
      [identifier <> @google_domain, identifier]
    end
  end
end

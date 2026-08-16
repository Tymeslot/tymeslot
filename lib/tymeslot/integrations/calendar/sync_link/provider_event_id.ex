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
  """

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
end

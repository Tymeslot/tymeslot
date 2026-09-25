defmodule Tymeslot.CalendarGrid.Occurrence do
  @moduledoc """
  What the grid needs to know about an event's place in a recurring series,
  shared by every write that can be scoped to part of one (deletes and edits).

  Both questions are asked of the cached row, which is the only copy that
  reliably says which series and occurrence an event is: callers of the grid
  writes often pass an address or an optimistic copy built from a form.
  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Utils.MapKeys

  @typedoc """
  How a series member's provider addresses part of a series:

    * `:single` - the event belongs to no series.
    * `:provider_ids` - Google and Outlook give every occurrence an id of its
      own, and the series its master's.
    * `:caldav` - the CalDAV family holds a whole series in one resource,
      addressed by its href; an occurrence is a part of that document.
    * `:unsupported` - no scoped write (Exchange, and anything else).
  """
  @type series_family :: :single | :provider_ids | :caldav | :unsupported

  @doc """
  Which family of scoped writes `event` takes. Reads the provider in either
  its string or atom form, and the series markers in either key shape.
  """
  @spec series_family(map()) :: series_family()
  def series_family(event) do
    provider = Map.get(event, :provider)

    cond do
      not Series.member?(event) -> :single
      ProviderConfig.caldav_based?(provider) -> :caldav
      ProviderConfig.oauth_provider?(provider) -> :provider_ids
      true -> :unsupported
    end
  end

  @doc """
  The key a CalDAV occurrence is cached under, after its series' UID.

  An expanded occurrence's uid is the series' UID, an underscore, and the
  occurrence's key, which is what the writer matches a `RECURRENCE-ID`
  against. A uid that does not carry that prefix names no occurrence the
  writer could find, and guessing one could write to the wrong day, so it is
  `{:error, :unaddressable_occurrence}`.
  """
  @spec occurrence_key(map()) :: {:ok, String.t()} | {:error, :unaddressable_occurrence}
  def occurrence_key(%{uid: uid} = stored) do
    prefix = "#{MapKeys.get_binary(Map.get(stored, :provider_metadata), :uid)}_"

    case String.split_at(uid, String.length(prefix)) do
      {^prefix, key} when prefix != "_" and key != "" -> {:ok, key}
      _unaddressable -> {:error, :unaddressable_occurrence}
    end
  end
end

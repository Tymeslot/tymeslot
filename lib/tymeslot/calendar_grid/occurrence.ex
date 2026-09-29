defmodule Tymeslot.CalendarGrid.Occurrence do
  @moduledoc """
  What the grid needs to know about an event's place in a recurring series,
  shared by every write that can take part or all of one (deletes, edits and
  moves).

  Every question is asked of the cached row (`cached_row/1`), which is the
  only copy that reliably says which series and occurrence an event is:
  callers of the grid writes often pass an address or an optimistic copy
  built from a form.
  """

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Utils.MapKeys

  # The original start Google ends an occurrence's uid and id with.
  @google_stamp ~r/_(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z)?\z/

  @typedoc """
  How a series member's provider addresses part of a series:

    * `:single` - the event belongs to no series.
    * `:provider_ids` - Google and Outlook give every occurrence an id of its
      own, and the series its master's.
    * `:caldav` - the CalDAV family holds a whole series in one resource,
      addressed by its href; an occurrence is a part of that document.
    * `:unsupported` - no scoped write (Exchange, and anything else): an
      edit is written to the one event, and a delete is refused.
  """
  @type series_family :: :single | :provider_ids | :caldav | :unsupported

  @typedoc """
  How a provider addresses a whole series: Google and Outlook by the id of
  its master event, the CalDAV family by the href of the resource holding it.
  """
  @type series_address :: {:master, String.t()} | {:resource, String.t()}

  @doc """
  The cached row of `event`, found by its integration and uid, or `event`
  itself when it has none.
  """
  @spec cached_row(map()) :: map()
  def cached_row(%{uid: uid, calendar_integration_id: integration_id} = event)
      when is_binary(uid) and is_integer(integration_id) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, row} -> row
      {:error, :not_found} -> event
    end
  end

  def cached_row(event), do: event

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
  How the provider of `stored`, a member of a series, addresses the whole
  series (see `t:series_address/0`).

  A Google or Outlook occurrence names its master in `recurring_event_id`;
  the master's own row carries a repeat rule and its id. A CalDAV member,
  occurrence or master, is part of the resource its href names.
  `{:error, :unaddressable_series}` when the row names neither, or its
  provider has no series-wide write.
  """
  @spec series_address(map()) :: {:ok, series_address()} | {:error, :unaddressable_series}
  def series_address(stored), do: series_address(series_family(stored), stored)

  defp series_address(:provider_ids, stored), do: master_address(stored)

  defp series_address(:caldav, %{provider_event_id: href}) when is_binary(href) and href != "",
    do: {:ok, {:resource, href}}

  defp series_address(_family, _stored), do: {:error, :unaddressable_series}

  defp master_address(%{recurring_event_id: master_id})
       when is_binary(master_id) and master_id != "",
       do: {:ok, {:master, master_id}}

  defp master_address(%{recurrence_rule: rule, provider_event_id: own_id})
       when is_binary(rule) and rule != "" and is_binary(own_id) and own_id != "",
       do: {:ok, {:master, own_id}}

  defp master_address(_stored), do: {:error, :unaddressable_series}

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

  @doc """
  Where the series first put a Google or Outlook occurrence: its original
  start, which the series' rule and exceptions name, whether or not the
  occurrence was moved on its own since. A `Date` for an all-day
  occurrence, the instant otherwise.

    * Google caches an occurrence under a uid, and gives it an id, that end
      in its original start (see `Google.EventNormaliser.cache_uid/1`):
      `YYYYMMDDTHHMMSSZ` in UTC, or `YYYYMMDD` all-day.
    * Outlook states it as the occurrence's `originalStart`; an occurrence
      never edited on its own (`type` `occurrence`) starts where the series
      put it.

  `{:error, :unaddressable_occurrence}` when neither says, since a guess
  could split the series on the wrong day.
  """
  @spec original_start(map()) ::
          {:ok, Date.t() | DateTime.t()} | {:error, :unaddressable_occurrence}
  def original_start(%{provider: provider} = stored) do
    case to_string(provider) do
      "google" -> google_original_start(stored)
      "outlook" -> outlook_original_start(stored)
      _other -> {:error, :unaddressable_occurrence}
    end
  end

  defp google_original_start(stored) do
    stamp =
      Enum.find_value([Map.get(stored, :uid), Map.get(stored, :provider_event_id)], fn id ->
        is_binary(id) and Regex.run(@google_stamp, id, capture: :all_but_first)
      end)

    with [y, m, d | time] <- stamp,
         {:ok, date} <- Date.new(int(y), int(m), int(d)),
         {:ok, start} <- stamp_start(date, time) do
      {:ok, start}
    else
      _unstamped -> {:error, :unaddressable_occurrence}
    end
  end

  defp stamp_start(date, []), do: {:ok, date}

  defp stamp_start(date, [hh, mm, ss]) do
    with {:ok, time} <- Time.new(int(hh), int(mm), int(ss)), do: DateTime.new(date, time)
  end

  defp outlook_original_start(stored) do
    metadata = Map.get(stored, :provider_metadata) || %{}

    with value when is_binary(value) <- MapKeys.get_binary(metadata, :originalStart),
         {:ok, instant, _offset} <- DateTime.from_iso8601(value) do
      {:ok, instant}
    else
      _unstated -> unmoved_start(MapKeys.get_binary(metadata, :type), stored)
    end
  end

  defp unmoved_start("occurrence", %{all_day: true, start_date: %Date{} = date}), do: {:ok, date}
  defp unmoved_start("occurrence", %{start_at: %DateTime{} = start}), do: {:ok, start}
  defp unmoved_start(_type, _stored), do: {:error, :unaddressable_occurrence}

  defp int(digits), do: String.to_integer(digits)
end

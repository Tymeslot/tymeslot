defmodule Tymeslot.CalendarGrid.CalendarDirectory do
  @moduledoc """
  The calendars the calendar's rail lists, grouped by the account
  (integration) they belong to.

  Only calendars marked `selected` in an account's `calendar_list` appear: an
  unselected calendar is not synced, so it has no events to show or hide.
  Each row carries its colour token, whether Tymeslot can write to it,
  whether its busy time blocks the booking page (`Blocking.blocks?/2`, which
  knows an Exchange mailbox's rule), and whether the organiser has hidden it.
  `hidden_count/1` is the number the filter chip shows when the rail is
  collapsed, so hidden calendars never go unnoticed.

  A calendar is named across the server and the hook by its key,
  `"<integration id>:<calendar id>"` (`key/2`, `parse_key/1`).
  `writable_calendars/1` is the one rule for which calendars a new event can
  be written to.
  """

  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @type calendar :: %{
          id: String.t(),
          name: String.t(),
          colour: String.t(),
          read_only: boolean(),
          blocks: boolean(),
          hidden: boolean()
        }

  @type account :: %{
          id: integer(),
          name: String.t(),
          colour: String.t(),
          read_only: boolean(),
          hidden: boolean(),
          calendars: [calendar()]
        }

  @doc """
  The rail's accounts, in the order the integrations are given. A calendar's
  `hidden` flag is its own choice only: inside a hidden account it can still
  be `false`, so a reader combines it with the account's flag.
  """
  @spec accounts([map()], map(), map(), [integer()], MapSet.t()) :: [account()]
  def accounts(integrations, integration_tokens, calendar_tokens, hidden_ids, hidden_keys) do
    Enum.map(integrations, fn integration ->
      provider_read_only = ProviderConfig.read_only?(integration.provider)
      colour = Map.get(integration_tokens, integration.id, ColourTokens.fallback())

      # `Blocking.blocks?/2` reads an Exchange mailbox's whole list (which
      # calendar is its main one), so it is given the list read as entries.
      readable = with_entries(integration)

      calendars =
        readable
        |> synced_entries()
        |> Enum.map(fn entry ->
          key = {integration.id, entry.id}

          %{
            id: entry.id,
            name: entry.name || entry.id,
            colour: Map.get(calendar_tokens, key, colour),
            read_only: provider_read_only or entry.read_only,
            blocks: Blocking.blocks?(readable, entry),
            hidden: MapSet.member?(hidden_keys, key)
          }
        end)

      %{
        id: integration.id,
        name: integration.name,
        colour: colour,
        read_only: provider_read_only,
        hidden: integration.id in hidden_ids,
        calendars: calendars
      }
    end)
  end

  @doc """
  How many calendars are hidden: every calendar of a hidden account (an
  account listing none counts as one), plus each calendar hidden on its own.
  """
  @spec hidden_count([account()]) :: non_neg_integer()
  def hidden_count(accounts) do
    Enum.reduce(accounts, 0, fn
      %{hidden: true, calendars: []}, count -> count + 1
      %{hidden: true, calendars: calendars}, count -> count + length(calendars)
      %{calendars: calendars}, count -> count + Enum.count(calendars, & &1.hidden)
    end)
  end

  @doc """
  An account's synced calendars (those marked `selected`), in its
  `calendar_list` order. The list is persisted as embedded entries, but a
  hand-written row or an older record may still hold plain maps, so each is
  normalised before it is read.
  """
  @spec synced_entries(map()) :: [CalendarEntry.t()]
  def synced_entries(%{calendar_list: list}) when is_list(list) do
    list
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.filter(&(&1.selected and is_binary(&1.id)))
  end

  def synced_entries(_integration), do: []

  defp with_entries(integration),
    do:
      Map.put(
        integration,
        :calendar_list,
        integration
        |> Map.get(:calendar_list)
        |> List.wrap()
        |> Enum.map(&CalendarEntry.normalize/1)
      )

  @doc "The key a calendar goes by in the payload and in a create."
  @spec key(integer(), String.t()) :: String.t()
  def key(integration_id, calendar_id), do: "#{integration_id}:#{calendar_id}"

  @doc """
  Reads a key back. Only the first colon separates: a calendar id may hold
  colons of its own.
  """
  @spec parse_key(term()) :: {:ok, integer(), String.t()} | :error
  def parse_key(key) when is_binary(key) do
    with [id, calendar_id] when calendar_id != "" <- String.split(key, ":", parts: 2),
         {integration_id, ""} <- Integer.parse(id) do
      {:ok, integration_id, calendar_id}
    else
      _unreadable -> :error
    end
  end

  def parse_key(_key), do: :error

  @doc """
  The calendars of `integration` a new event can be written to: synced, not
  read-only, on a provider that takes writes.
  """
  @spec writable_calendars(map()) :: [CalendarEntry.t()]
  def writable_calendars(%{provider: provider} = integration) do
    if ProviderConfig.read_only?(provider),
      do: [],
      else: integration |> synced_entries() |> Enum.reject(& &1.read_only)
  end

  @doc """
  The calendars a new event can go to, for the quick-create calendar chip:
  every writable calendar of `accounts` (as `accounts/5` builds them),
  hidden ones included, in rail order.
  """
  @spec choices([account()]) :: [
          %{key: String.t(), name: String.t(), account: String.t(), colour: String.t()}
        ]
  def choices(accounts) do
    for %{read_only: false} = account <- accounts,
        %{read_only: false} = calendar <- account.calendars do
      %{
        key: key(account.id, calendar.id),
        name: calendar.name,
        account: account.name,
        colour: calendar.colour
      }
    end
  end

  @doc """
  The calendar quick create starts on: the first account with a writable
  calendar, on its booking calendar when that is writable, else its primary
  or first writable one (`Calendar.default_booking_calendar/2`). `nil` when
  nothing can be written to.
  """
  @spec default_calendar([map()]) :: String.t() | nil
  def default_calendar(integrations) do
    Enum.find_value(integrations, fn integration ->
      booking_id = Map.get(integration, :default_booking_calendar_id)

      case Calendar.default_booking_calendar(writable_calendars(integration), booking_id) do
        nil -> nil
        entry -> key(integration.id, entry.id)
      end
    end)
  end
end

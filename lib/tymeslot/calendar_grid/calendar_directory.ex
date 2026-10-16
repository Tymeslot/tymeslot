defmodule Tymeslot.CalendarGrid.CalendarDirectory do
  @moduledoc """
  The calendars the redesigned calendar's rail lists, grouped by the account
  (integration) they belong to.

  Only calendars marked `selected` in an account's `calendar_list` appear: an
  unselected calendar is not synced, so it has no events to show or hide.
  Each row carries its colour token, whether Tymeslot can write to it, and
  whether the organiser has hidden it. `hidden_count/1` is the number the
  filter chip shows when the rail is collapsed, so hidden calendars never go
  unnoticed.
  """

  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @type calendar :: %{
          id: String.t(),
          name: String.t(),
          colour: String.t(),
          read_only: boolean(),
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

      calendars =
        integration
        |> synced_entries()
        |> Enum.map(fn entry ->
          key = {integration.id, entry.id}

          %{
            id: entry.id,
            name: entry.name || entry.id,
            colour: Map.get(calendar_tokens, key, colour),
            read_only: provider_read_only or entry.read_only,
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

  # `calendar_list` is persisted as embedded entries, but a hand-written row
  # or an older record may still be a plain map, so normalise before reading.
  defp synced_entries(%{calendar_list: list}) when is_list(list) do
    list
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.filter(&(&1.selected and is_binary(&1.id)))
  end

  defp synced_entries(_integration), do: []
end

defmodule Tymeslot.Integrations.Calendar.AvailabilityView do
  @moduledoc """
  Which of an integration's calendars the availability reads take in: the
  ones the owner lets block (`Selection.blocking?/1`).

  `of/1` is the live read's half, `rules/1` the cached reads'. Both give the
  same answer for the same integration:

    * no calendar list (it predates selection), or nothing selected (Google
      and Outlook then read the account's primary calendar): read whole, as
      before the choice existed;
    * calendars selected and none blocking: not read at all;
    * otherwise: its blocking calendars only, read-only ones included.

  An Exchange mailbox's busy time is read for the whole mailbox, cached
  under no folder's id, and stands for its main calendar: it is read
  whole unless the owner has set that calendar not to block, whether or not
  it is shown, and not at all if they have. Its other folders never block.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Selection

  @doc """
  The integration as the live availability read must see it: `calendar_list`
  narrowed to its blocking calendars, with `calendar_paths` to match, the
  integration unchanged when it is read whole, or `nil` when it is not read.

  Dropping an integration rather than passing it on with an empty list is
  load-bearing: Google and Outlook read the account's primary calendar when
  no calendar is selected.
  """
  @spec of(map()) :: map() | nil
  def of(integration) do
    case reading(integration) do
      :whole -> integration
      :none -> nil
      {:only, blocking} -> narrow(integration, blocking)
    end
  end

  @doc """
  Per integration id, the `t:Selection.visibility_rule/0` that keeps only the
  cached rows `of/1` would read: `:all` for an integration read whole,
  `:none` for one not read.
  """
  @spec rules([map()]) :: %{integer() => Selection.visibility_rule()}
  def rules(integrations) do
    Map.new(integrations, fn integration ->
      rule =
        case reading(integration) do
          :whole ->
            :all

          :none ->
            :none

          {:only, blocking} ->
            Selection.entries_rule(blocking ++ primary_alias(integration, blocking))
        end

      {integration.id, rule}
    end)
  end

  defp reading(%{calendar_list: list} = integration) do
    entries = Enum.map(list || [], &CalendarEntry.normalize/1)

    cond do
      ProviderConfig.ews?(Map.get(integration, :provider)) -> mailbox_reading(entries)
      not Enum.any?(entries, & &1.selected) -> :whole
      true -> only(Selection.blocking_calendars(entries))
    end
  end

  # A mailbox whose main calendar is not listed (connected before folders
  # were, or a server naming none the default) blocks as it always did.
  defp mailbox_reading(entries) do
    case Enum.find(entries, & &1.primary) do
      %CalendarEntry{blocks_availability: false} -> :none
      _blocking_or_unknown -> :whole
    end
  end

  # Google and Outlook rows cached before discovery named the account's
  # default calendar are filed under "primary", the name both APIs give it,
  # until a later read relabels them (`Outlook.FeedCalendar`). They are that
  # calendar's rows, so they block exactly when it does.
  @primary_alias "primary"

  defp primary_alias(integration, blocking) do
    if ProviderConfig.in_family?(Map.get(integration, :provider), :oauth) and
         Enum.any?(blocking, & &1.primary),
       do: [%CalendarEntry{id: @primary_alias}],
       else: []
  end

  defp only([]), do: :none
  defp only(blocking), do: {:only, blocking}

  defp narrow(integration, blocking) do
    Map.merge(integration, %{
      calendar_list: blocking,
      calendar_paths: Selection.derive_selected_paths(blocking)
    })
  end
end

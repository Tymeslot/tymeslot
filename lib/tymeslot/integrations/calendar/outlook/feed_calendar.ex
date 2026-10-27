defmodule Tymeslot.Integrations.Calendar.Outlook.FeedCalendar do
  @moduledoc """
  The calendar an Outlook integration's delta feed covers, and the label its
  cached rows are filed under.

  The feed is `/me/calendarView/delta`: the account's default calendar. Its
  rows are filed under that calendar's real Graph id, as discovery lists it
  (`calendar_list`), so the grid's per-calendar selection and colour find
  them. Before discovery has marked a default (an integration connected
  before the field existed), they are filed under `"primary"`, the name the
  rest of the Outlook code gives the default calendar.

  The bootstrap and the delta used to label the same rows differently (the
  booking calendar's id, and `"primary"`), and the cache keeps a row's first
  label. `relabel/2` corrects that on every feed read: the rows the read
  returned, and every row still filed under `"primary"`, move to the feed's
  calendar.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarLabelQueries

  @unnamed "primary"

  @doc "The id the feed's rows are filed under."
  @spec id(CalendarIntegrationSchema.t()) :: String.t()
  def id(%CalendarIntegrationSchema{calendar_list: calendar_list}) do
    case Enum.find(calendar_list || [], &(&1.primary == true)) do
      %{id: id} when is_binary(id) and id != "" -> id
      _unknown -> @unnamed
    end
  end

  @doc """
  Files under the feed's calendar the rows with `uids`, which a feed read
  just returned, and every row still filed under `"primary"`.
  """
  @spec relabel(CalendarIntegrationSchema.t(), [String.t()]) :: non_neg_integer()
  def relabel(%CalendarIntegrationSchema{} = integration, uids),
    do: ProviderCalendarLabelQueries.relabel(integration.id, id(integration), uids, [@unnamed])
end

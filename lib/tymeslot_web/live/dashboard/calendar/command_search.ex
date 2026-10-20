defmodule TymeslotWeb.Dashboard.Calendar.CommandSearch do
  @moduledoc """
  The command bar's server search (`CommandBar`). The bar's input reaches
  `calendar:command_query` (debounced 200 ms in the browser); from two
  characters it runs `CalendarGrid.search_calendar/5` off the process
  (`start_async/3`, any search still running cancelled first) and turns the
  hits into rows carrying what the hook's reveal needs: the payload ids, the
  local date and start minute, and whether the event is all day.

  An answer is taken only while its query is still the one typed, so a late
  answer never replaces a newer one or refills a closed bar.
  `calendar:command_close` (pushed by the bar's `data-hide`) resets the bar.
  The search follows the effective visibility the surface holds, so hidden
  calendars and calendars outside the active set are left out.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  require Logger

  @min_length 2
  # Longer than any title worth searching for; keeps the ILIKE pattern small.
  @max_length 100

  @type row :: %{
          dom_id: String.t(),
          ids: [String.t()],
          title: String.t(),
          when_label: String.t(),
          date: Date.t(),
          start_min: non_neg_integer() | nil,
          all_day: boolean(),
          colour: String.t() | nil,
          series: boolean(),
          detail: String.t() | nil
        }

  @doc "The `command` assign of a closed or empty bar."
  @spec empty() :: map()
  def empty, do: %{query: "", events: [], bookings: [], loading: false, error: false}

  @doc "Answers `calendar:command_query` and `calendar:command_close`."
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle("calendar:command_query", %{"q" => query}, socket) when is_binary(query),
    do: {:noreply, search(socket, query)}

  def handle("calendar:command_close", _params, socket),
    do: {:noreply, socket |> cancel_async(:command_search) |> assign(:command, empty())}

  def handle(_event, _params, socket), do: {:noreply, socket}

  @doc "Takes a search's answer, unless the bar has moved on to another query since."
  @spec async(:command_search, term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def async(
        :command_search,
        {:ok, {query, hits}},
        %{assigns: %{command: %{query: query}}} = socket
      ) do
    %{events: events, bookings: bookings} = rows(hits, socket.assigns)

    {:noreply,
     assign(socket, :command, %{
       query: query,
       events: events,
       bookings: bookings,
       loading: false,
       error: false
     })}
  end

  def async(:command_search, {:ok, _stale}, socket), do: {:noreply, socket}

  def async(:command_search, {:exit, reason}, socket) do
    if reason != {:shutdown, :cancel},
      do: Logger.warning("Calendar search failed", reason: LogFormat.reason(reason))

    {:noreply,
     assign(socket, :command, %{
       socket.assigns.command
       | events: [],
         bookings: [],
         loading: false,
         error: reason != {:shutdown, :cancel}
     })}
  end

  @doc "The bar's rows for `hits` (see `CalendarGrid.search_calendar/5`), in the organiser's zone and clock."
  @spec rows(%{events: [map()], bookings: [map()]}, map()) :: %{
          events: [row()],
          bookings: [row()]
        }
  def rows(%{events: events, bookings: bookings}, assigns) do
    context = %{
      timezone: assigns.timezone,
      time_format: assigns.time_format,
      today: assigns.today,
      locale: Gettext.get_locale(TymeslotWeb.Gettext),
      accounts: assigns.accounts,
      integration_tokens: assigns.integration_tokens,
      calendar_tokens: assigns.calendar_tokens
    }

    %{
      events: Enum.map(events, &row(&1, context)),
      bookings: Enum.map(bookings, &row(&1, context))
    }
  end

  defp search(socket, raw) do
    query = raw |> String.trim() |> String.slice(0, @max_length)
    socket = cancel_async(socket, :command_search)

    if String.length(query) < @min_length do
      assign(socket, :command, %{empty() | query: query})
    else
      %{current_user: user, integrations: integrations} = socket.assigns
      visibility = visibility(socket.assigns)
      now = Clock.utc_now()

      socket
      |> assign(:command, %{socket.assigns.command | query: query, loading: true, error: false})
      |> start_async(
        :command_search,
        Tasks.with_context(fn ->
          {query,
           CalendarGrid.search_calendar(user.id, query, integrations, visibility, now: now)}
        end)
      )
    end
  end

  # The surface's hidden assigns already hold the effective visibility.
  defp visibility(assigns) do
    %EffectiveVisibility{
      hidden_integration_ids: assigns.hidden_integration_ids,
      hidden_calendar_keys: assigns.hidden_calendar_keys,
      active_set: assigns.active_set
    }
  end

  defp row(hit, context) do
    {date, start_min} = local(hit.start, context.timezone)

    %{
      dom_id: "calendar-command-row-" <> hit.id,
      ids: hit.ids,
      title: hit.title,
      when_label: when_label(hit, date, context),
      date: date,
      start_min: start_min,
      all_day: hit.all_day,
      colour: ColourTokens.for_event(hit, context.integration_tokens, context.calendar_tokens),
      series: hit.series,
      detail: detail(hit, context.accounts)
    }
  end

  defp local(%Date{} = date, _timezone), do: {date, nil}

  defp local(%DateTime{} = at, timezone) do
    local = DateTime.shift_zone!(at, timezone)
    {DateTime.to_date(local), local.hour * 60 + local.minute}
  end

  defp when_label(%{all_day: true}, date, context),
    do: dgettext("dashboard_calendar", "%{date}, all day", date: day_label(date, context))

  defp when_label(%{start: %DateTime{} = start}, date, context) do
    time =
      start
      |> DateTime.shift_zone!(context.timezone)
      |> DateTime.to_time()
      |> TimeFormat.format(context.time_format)

    "#{day_label(date, context)}, #{time}"
  end

  # A hit in another year names its year: past hits can be years old.
  defp day_label(%Date{year: year} = date, %{today: %Date{year: year}, locale: locale}),
    do: LocaleFormat.format_short_weekday_date(date, locale)

  defp day_label(date, %{locale: locale}),
    do: LocaleFormat.format_short_date_with_year(date, locale)

  defp detail(%{kind: :booking, meeting_type: type}, _accounts), do: type

  defp detail(%{calendar_integration_id: id, provider_calendar_id: calendar_id}, accounts) do
    case Enum.find(accounts, &(&1.id == id)) do
      nil ->
        nil

      account ->
        Enum.find_value(account.calendars, account.name, &(&1.id == calendar_id && &1.name))
    end
  end
end

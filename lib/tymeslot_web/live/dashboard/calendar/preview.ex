defmodule TymeslotWeb.Dashboard.Calendar.Preview do
  @moduledoc """
  The read-only preview that opens when an event on the grid is clicked:
  which calendar it sits in, when it is (with how far away), where, who,
  whether guests can book over it, and whether it is still waiting to sync.

  Rendered by LiveView rather than by the hook from payload data: it needs
  translated, locale-formatted text and rules only the server holds (account
  and calendar names, whether a calendar blocks bookings), and later plans
  add actions to it that are server writes anyway. The hook only positions it
  (CSS variables on `<html>`) and takes focus back when it closes.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  @guest_limit 5

  @doc "What `build/2` needs from the surface's assigns."
  @spec context(map()) :: map()
  def context(assigns) do
    %{
      timezone: assigns.timezone,
      time_format: assigns.time_format,
      locale: Gettext.get_locale(TymeslotWeb.Gettext),
      now: Clock.utc_now(),
      integrations: assigns.integrations,
      integration_tokens: assigns.integration_tokens,
      calendar_tokens: assigns.calendar_tokens
    }
  end

  @doc "The preview's content for `event`."
  @spec build(map(), map()) :: map()
  def build(event, context) do
    {integration, entry} = source(event, context.integrations)

    %{
      title: EventPayload.title(event),
      colour: ColourTokens.for_event(event, context.integration_tokens, context.calendar_tokens),
      source: source_label(event, integration, entry),
      when: when_text(event, context),
      relative: relative(event, context.now),
      repeats:
        is_binary(Map.get(event, :recurrence_rule)) or
          is_binary(Map.get(event, :recurring_event_id)),
      location: present(Map.get(event, :location)),
      guests: guests(event),
      join_url: web_url(Map.get(event, :video_link) || Map.get(event, :join_url)),
      availability: availability(event, integration, entry),
      sync_note: sync_note(event, integration)
    }
  end

  attr :preview, :map, required: true
  attr :target, :any, required: true

  @spec preview(map()) :: Phoenix.LiveView.Rendered.t()
  def preview(assigns) do
    ~H"""
    <div
      id="calendar-preview"
      class="cal-preview"
      role="dialog"
      aria-labelledby="calendar-preview-title"
      tabindex="-1"
      phx-click-away="calendar:close_preview"
      phx-window-keydown="calendar:close_preview"
      phx-key="escape"
      phx-target={@target}
    >
      <div class="flex items-start gap-3">
        <span
          class="cal-preview-swatch"
          style={"--cal-ev: var(--color-#{@preview.colour})"}
          aria-hidden="true"
        ></span>
        <h2
          id="calendar-preview-title"
          class="min-w-0 flex-1 break-words text-token-base font-semibold text-tymeslot-900"
        >
          {@preview.title}
        </h2>
        <.icon_button
          icon="hero-x-mark"
          size={:sm}
          label={dgettext("dashboard_calendar", "Close")}
          phx-click="calendar:close_preview"
          phx-target={@target}
        />
      </div>
      <div class="mt-3 space-y-2 text-token-sm text-tymeslot-700">
        <.row :if={@preview.source} icon="hero-calendar">{@preview.source}</.row>
        <.row icon="hero-clock">
          {@preview.when}<span :if={@preview.relative} class="text-tymeslot-500"> · {@preview.relative}</span>
        </.row>
        <.row :if={@preview.repeats} icon="hero-arrow-path">
          {dgettext("dashboard_calendar", "Repeats")}
        </.row>
        <.row :if={@preview.location} icon="hero-map-pin">
          <span class="break-words">{@preview.location}</span>
        </.row>
        <.row :if={@preview.guests != []} icon="hero-user-group">{guest_text(@preview.guests)}</.row>
        <.row icon="hero-shield-check">
          <strong class="font-semibold">{@preview.availability.label}</strong>
          · {@preview.availability.note}
        </.row>
        <.row :if={@preview.sync_note} icon="hero-arrow-up-tray">
          <span class="text-amber-800">{@preview.sync_note}</span>
        </.row>
      </div>
      <div :if={@preview.join_url} class="mt-4">
        <.link
          href={@preview.join_url}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-700 px-3 py-1.5 text-token-sm font-semibold text-white hover:bg-turquoise-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        >
          <.icon name="hero-video-camera-mini" class="h-4 w-4" />
          {dgettext("dashboard_calendar", "Join")}
        </.link>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <.icon name={@icon} class="mt-0.5 h-4 w-4 shrink-0 text-tymeslot-400" />
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp source(%{kind: :booking}, _integrations), do: {nil, nil}

  defp source(event, integrations) do
    case Enum.find(integrations, &(&1.id == event.calendar_integration_id)) do
      nil -> {nil, nil}
      integration -> {integration, Selection.calendar_for_event(event, entries(integration))}
    end
  end

  defp entries(%{calendar_list: list}) when is_list(list),
    do: Enum.map(list, &CalendarEntry.normalize/1)

  defp entries(_integration), do: []

  defp source_label(%{kind: :booking}, _integration, _entry),
    do: dgettext("dashboard_calendar", "Tymeslot booking")

  defp source_label(_event, nil, _entry), do: nil

  defp source_label(_event, integration, %CalendarEntry{name: name})
       when is_binary(name) and name != "",
       do: "#{name} · #{integration.name}"

  defp source_label(_event, integration, _entry), do: integration.name

  defp when_text(%{all_day: true, start_date: %Date{} = first} = event, context) do
    last = Date.add(EventPayload.exclusive_end(event), -1)
    first_text = LocaleFormat.format_short_weekday_date(first, context.locale)

    if first == last,
      do: dgettext("dashboard_calendar", "%{date}, all day", date: first_text),
      else: "#{first_text} – #{LocaleFormat.format_short_weekday_date(last, context.locale)}"
  end

  defp when_text(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, context) do
    starts = DateTime.shift_zone!(start_at, context.timezone)
    ends = DateTime.shift_zone!(end_at, context.timezone)
    start_day = LocaleFormat.format_short_weekday_date(DateTime.to_date(starts), context.locale)
    start_time = TimeFormat.format(DateTime.to_time(starts), context.time_format)
    end_time = TimeFormat.format(DateTime.to_time(ends), context.time_format)

    if DateTime.to_date(starts) == DateTime.to_date(ends),
      do: "#{start_day}, #{start_time}–#{end_time}",
      else:
        "#{start_day}, #{start_time} – " <>
          "#{LocaleFormat.format_short_weekday_date(DateTime.to_date(ends), context.locale)}, #{end_time}"
  end

  defp relative(%{all_day: true}, _now), do: nil

  defp relative(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, now) do
    minutes = DateTime.diff(start_at, now, :minute)

    cond do
      DateTime.compare(end_at, now) != :gt ->
        dgettext("dashboard_calendar", "Ended")

      minutes <= 0 ->
        dgettext("dashboard_calendar", "Happening now")

      minutes < 60 ->
        dgettext("dashboard_calendar", "in %{count} min", count: minutes)

      minutes < 1440 ->
        dgettext("dashboard_calendar", "in %{count} h", count: div(minutes, 60))

      true ->
        dngettext("dashboard_calendar", "in %{count} day", "in %{count} days", div(minutes, 1440))
    end
  end

  defp guests(%{kind: :booking, participants: [_first | _rest] = participants}),
    do: Enum.map(participants, &(present(&1.name) || &1.email))

  defp guests(%{kind: :booking} = booking),
    do: Enum.reject([present(booking.attendee_name) || booking.attendee_email], &is_nil/1)

  defp guests(event) do
    event
    |> Map.get(:attendees, [])
    |> List.wrap()
    |> Enum.map(&Attendee.normalise/1)
    |> Enum.map(&(present(&1.display_name) || &1.email))
    |> Enum.reject(&is_nil/1)
  end

  defp guest_text(guests) do
    {shown, rest} = Enum.split(guests, @guest_limit)
    names = Enum.join(shown, ", ")

    if rest == [],
      do: names,
      else:
        dngettext(
          "dashboard_calendar",
          "%{names} and %{count} more",
          "%{names} and %{count} more",
          length(rest), names: names)
  end

  defp availability(event, integration, entry) do
    cond do
      Map.get(event, :kind) == :booking ->
        busy()

      Map.get(event, :transparency) == "transparent" ->
        free()

      blocking?(integration, entry) ->
        busy()

      true ->
        %{
          label: dgettext("dashboard_calendar", "Busy"),
          note: dgettext("dashboard_calendar", "This calendar doesn't block bookings")
        }
    end
  end

  defp blocking?(%{provider: _provider} = integration, %CalendarEntry{} = entry),
    do: Blocking.blocks?(integration, entry)

  defp blocking?(_integration, _entry), do: true

  defp busy,
    do: %{
      label: dgettext("dashboard_calendar", "Busy"),
      note: dgettext("dashboard_calendar", "Guests can't book this time")
    }

  defp free,
    do: %{
      label: dgettext("dashboard_calendar", "Free"),
      note: dgettext("dashboard_calendar", "Guests can book this time")
    }

  defp sync_note(event, integration) do
    if integration && Map.get(event, :sync_state, "synced") != "synced",
      do:
        dgettext("dashboard_calendar", "Saved here, waiting to reach %{account}",
          account: integration.name
        )
  end

  defp web_url(url) do
    case present(url) do
      nil -> nil
      value -> if URI.parse(value).scheme in ["https", "http"], do: value
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end

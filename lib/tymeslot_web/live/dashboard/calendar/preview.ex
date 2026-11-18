defmodule TymeslotWeb.Dashboard.Calendar.Preview do
  @moduledoc """
  The preview that opens when an event on the grid is clicked:
  which calendar it sits in, when it is (with how far away), where, who and
  how each has answered (`PreviewGuests`), a group booking's seats taken,
  whether guests can book over it,
  and whether it is still waiting to sync.

  Rendered by LiveView rather than by the hook from payload data: it needs
  translated, locale-formatted text and rules only the server holds (account
  and calendar names, whether a calendar blocks bookings), and later plans
  add actions to it that are server writes anyway. The hook only positions it
  (CSS variables on `<html>`) and takes focus back when it closes.

  An event a group meeting with live seats sits on says so, and offers
  nothing to change (`EditGuard.seat_locked?/2`). An event the organiser can
  change offers Edit (the side panel) and Delete
  (see `Deletion`), and a Busy/Free toggle unless it is a booking or a
  booking's calendar copy (`FreeBusy`). A booking offers what
  `BookingPreview` allows: Accept and Decline on a request, Reschedule and
  Cancel on a booking still ahead, or a quiet line once it has passed, and
  Move booking when the host moved its event in their calendar.
  A read-only all-day event offers "Treat as Busy | Free" instead (`TreatAs`), a choice
  kept in Tymeslot.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventBlocking
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.GuestReplies
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Dashboard.Calendar.BookingPreview
  alias TymeslotWeb.Dashboard.Calendar.LinkedText
  alias TymeslotWeb.Dashboard.Calendar.PreviewGuests
  alias TymeslotWeb.Dashboard.Calendar.TreatAs
  alias TymeslotWeb.Dashboard.Calendar.UndeliveredNotice
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Helpers.LocaleFormat

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
      calendar_tokens: assigns.calendar_tokens,
      bookability: Map.get(assigns, :bookability, %{}),
      locked_uids: Map.get(assigns, :locked_uids, MapSet.new()),
      colour_overrides: Map.get(assigns, :colour_overrides, %{}),
      user_id: assigns.current_user.id
    }
  end

  @doc "The preview's content for `event`."
  @spec build(map(), map()) :: map()
  def build(event, context) do
    {integration, entry} = source(event, context.integrations)
    locked = EditGuard.seat_locked?(Map.get(context, :locked_uids, MapSet.new()), event)

    %{
      id: EventPayload.id(event),
      title: EventPayload.title(event),
      colour:
        event
        |> ColourTokens.with_override(Map.get(context, :colour_overrides, %{}))
        |> ColourTokens.for_event(context.integration_tokens, context.calendar_tokens),
      source: source_label(event, integration, entry),
      when: when_text(event, context),
      relative: relative(event, context.now),
      repeats: EventPayload.recurring?(event),
      location: present(Map.get(event, :location)),
      notes: present(Map.get(event, :description)),
      guests: GuestReplies.of_event(event),
      seats: seats(event),
      join_url: web_url(Map.get(event, :video_link) || Map.get(event, :join_url)),
      availability: availability(event, integration, entry),
      sync_note: sync_note(event, integration),
      locked: locked,
      # A previewed occurrence of a series no sync has cached yet is edited
      # as its series, which Edit opens; it has nothing of its own to delete.
      editable:
        not locked and
          EditGuard.editable?(context.integrations, CalendarGrid.preview_series(event)),
      deletable: not CalendarGrid.preview?(event),
      free_busy: free_busy(event, context.integrations, locked),
      free: Map.get(event, :transparency) == "transparent",
      treat_as: TreatAs.state(event, blocking?(integration, entry), context),
      meeting_id: Map.get(event, :meeting_id),
      booking: BookingPreview.state(event, context.now),
      move_to: move_to(event, context),
      undelivered: UndeliveredNotice.for_event(event, context.user_id)
    }
  end

  attr :preview, :map, required: true
  attr :target, :any, required: true

  attr :answering, :any,
    default: MapSet.new(),
    doc: "the ids of the meetings whose request answer is in flight"

  attr :moving, :any, default: MapSet.new(), doc: "the ids of the bookings being moved"

  @spec preview(map()) :: Phoenix.LiveView.Rendered.t()
  def preview(assigns) do
    ~H"""
    <%!-- On a phone the preview is a bottom sheet (calendar-phone.css). The
         scrim behind it dims the grid and takes the tap that closes it (the
         preview's click-away), so that tap never lands on the grid. --%>
    <div class="cal-scrim sm:hidden" aria-hidden="true"></div>
    <div
      id="calendar-preview"
      class="cal-preview"
      role="dialog"
      aria-labelledby="calendar-preview-title"
      tabindex="-1"
      phx-click-away={JS.push("calendar:close_preview", value: %{refocus: false}, target: @target)}
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
      <UndeliveredNotice.notice
        :if={@preview.undelivered != []}
        emails={@preview.undelivered}
        target={@target}
      />
      <div class="mt-3 space-y-2 text-token-sm text-tymeslot-700">
        <.row :if={@preview.source} icon="hero-calendar">{@preview.source}</.row>
        <.row icon="hero-clock">
          {@preview.when}<span :if={@preview.relative} class="text-tymeslot-500"> · {@preview.relative}</span>
        </.row>
        <.row :if={@preview.repeats} icon="hero-arrow-path">
          {dgettext("dashboard_calendar", "Repeats")}
        </.row>
        <.row :if={@preview.location} icon="hero-map-pin">
          <LinkedText.linked_text
            id="calendar-preview-location"
            text={@preview.location}
            class="break-words"
          />
        </.row>
        <.row :if={@preview.notes} icon="hero-bars-3-bottom-left">
          <LinkedText.linked_text
            id="calendar-preview-notes"
            text={@preview.notes}
            class="block max-h-40 overflow-y-auto whitespace-pre-line break-words"
          />
        </.row>
        <.row :if={@preview.seats} icon="hero-users">
          <span id="calendar-preview-seats">
            {dgettext("dashboard_calendar", "%{count}/%{capacity} seats taken",
              count: @preview.seats.taken,
              capacity: @preview.seats.capacity
            )}
          </span>
        </.row>
        <PreviewGuests.guests :if={@preview.guests != []} guests={@preview.guests} />
        <.row :if={@preview.availability} icon="hero-shield-check">
          <div :if={@preview.free_busy == :editable} class="flex flex-wrap items-center gap-2">
            <div
              class="inline-flex rounded-token-lg border border-tymeslot-200 p-0.5"
              role="group"
              aria-label={dgettext("dashboard_calendar", "Show as")}
            >
              <button
                :for={{free, id, label} <- free_busy_choices()}
                id={id}
                type="button"
                aria-pressed={to_string(@preview.free == free)}
                phx-click="calendar:set_free"
                phx-value-id={@preview.id}
                phx-value-free={to_string(free)}
                phx-target={@target}
                class={[
                  "rounded-token-md px-2.5 py-0.5 text-token-sm focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
                  if(@preview.free == free,
                    do: "bg-turquoise-50 font-semibold text-turquoise-800",
                    else: "text-tymeslot-600 hover:bg-tymeslot-50"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <span>{@preview.availability.note}</span>
          </div>
          <TreatAs.control :if={@preview.treat_as} preview={@preview} target={@target} />
          <span :if={@preview.free_busy != :editable and is_nil(@preview.treat_as)}>
            <strong class="font-semibold">{@preview.availability.label}</strong>
            · {@preview.availability.note}
          </span>
          <span :if={@preview.free_busy == :booking} class="block text-tymeslot-500">
            {dgettext("dashboard_calendar", "Set in the meeting type")}
          </span>
        </.row>
        <.row :if={@preview.locked} icon="hero-lock-closed">
          <span id="calendar-preview-locked" class="text-tymeslot-600">
            {CalendarEditMessages.seat_lock_message()}
          </span>
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
      <BookingPreview.booking_actions
        preview={@preview}
        answering={@answering}
        moving={@moving}
        target={@target}
      />
      <div
        :if={@preview.editable}
        class="mt-4 flex justify-end gap-2 border-t border-tymeslot-100 pt-3"
      >
        <.action_button
          id="calendar-preview-edit"
          variant={:secondary}
          size={:sm}
          icon="hero-pencil-square"
          phx-click="calendar:edit"
          phx-value-id={@preview.id}
          phx-target={@target}
        >
          {dgettext("dashboard_calendar", "Edit")}
        </.action_button>
        <.action_button
          :if={@preview.deletable}
          id="calendar-preview-delete"
          variant={:danger_soft}
          size={:sm}
          icon="hero-trash"
          phx-click="calendar:delete"
          phx-value-id={@preview.id}
          phx-target={@target}
        >
          {dgettext("dashboard_calendar", "Delete")}
        </.action_button>
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

  # A group booking's seats: those taken (its people and their guests) of
  # its capacity. A one-to-one booking has none to count.
  defp seats(%{kind: :booking, capacity: capacity, seats_taken: taken}) when capacity > 1,
    do: %{taken: taken, capacity: capacity}

  defp seats(_event), do: nil

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

  defp source_label(%{kind: :booking, copy: %{calendar_name: name}}, _integration, _entry)
       when is_binary(name) and name != "",
       do:
         dgettext("dashboard_calendar_booking", "Tymeslot booking · %{calendar}", calendar: name)

  defp source_label(%{kind: :booking}, _integration, _entry),
    do: dgettext("dashboard_calendar", "Tymeslot booking")

  defp source_label(_event, nil, _entry), do: nil

  defp source_label(_event, integration, %CalendarEntry{name: name})
       when is_binary(name) and name != "",
       do:
         dgettext("dashboard_calendar", "%{calendar} · %{account}",
           calendar: name,
           account: integration.name
         )

  defp source_label(_event, integration, _entry), do: integration.name

  defp when_text(%{all_day: true, start_date: %Date{} = first} = event, context) do
    last = Date.add(EventPayload.exclusive_end(event), -1)
    first_text = LocaleFormat.format_short_weekday_date(first, context.locale)

    if first == last,
      do: dgettext("dashboard_calendar", "%{date}, all day", date: first_text),
      else:
        dgettext("dashboard_calendar", "%{first} – %{last}",
          first: first_text,
          last: LocaleFormat.format_short_weekday_date(last, context.locale)
        )
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
        dgettext("dashboard_calendar", "%{start_day}, %{start_time} – %{end_day}, %{end_time}",
          start_day: start_day,
          start_time: start_time,
          end_day: LocaleFormat.format_short_weekday_date(DateTime.to_date(ends), context.locale),
          end_time: end_time
        )
  end

  # The time the host moved a booking's event to in their calendar, worded
  # like the time row above it; nil when the booking cannot follow it.
  defp move_to(%{kind: :booking, move_offer: %{start_time: start_at, end_time: end_at}}, context),
    do: when_text(%{start_at: start_at, end_at: end_at}, context)

  defp move_to(_event, _context), do: nil

  defp relative(%{all_day: true}, _now), do: nil

  defp relative(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, now) do
    seconds = DateTime.diff(start_at, now, :second)

    cond do
      DateTime.compare(end_at, now) != :gt -> dgettext("dashboard_calendar", "Ended")
      seconds <= 0 -> dgettext("dashboard_calendar", "Happening now")
      true -> away(max(1, round(seconds / 60)))
    end
  end

  # Rounded to the nearest unit, so 1 h 59 min reads "in 2 h".
  defp away(minutes) when minutes < 60,
    do: dgettext("dashboard_calendar", "in %{count} min", count: minutes)

  defp away(minutes) do
    hours = round(minutes / 60)

    if hours < 24,
      do: dgettext("dashboard_calendar", "in %{count} h", count: hours),
      else:
        dngettext(
          "dashboard_calendar",
          "in %{count} day",
          "in %{count} days",
          round(minutes / 1440)
        )
  end

  # Whether the toggle is offered: a booking and a booking's calendar copy
  # follow their meeting type; a read-only event shows its state only. An
  # editable event the toggle refuses is a booking's calendar copy.
  defp free_busy(%{kind: :booking}, _integrations, _locked), do: :booking
  defp free_busy(_event, _integrations, true), do: :read_only

  defp free_busy(event, integrations, false) do
    cond do
      EditGuard.free_busy_editable?(integrations, event) -> :editable
      EditGuard.editable?(integrations, event) -> :booking
      true -> :read_only
    end
  end

  defp free_busy_choices,
    do: [
      {false, "calendar-preview-busy", dgettext("dashboard_calendar", "Busy")},
      {true, "calendar-preview-free", dgettext("dashboard_calendar", "Free")}
    ]

  # A request the sweep expired no longer holds its slot, so it says nothing
  # about whether guests can book that time.
  defp availability(%{kind: :booking, expired: true, request: false}, _integration, _entry),
    do: nil

  defp availability(%{kind: :booking}, _integration, _entry), do: busy()

  defp availability(event, integration, entry) do
    cond do
      not EventBlocking.blocks?(event, integration) -> free()
      blocking?(integration, entry) -> busy()
      true -> not_blocking()
    end
  end

  defp blocking?(%{provider: _provider} = integration, %CalendarEntry{} = entry),
    do: Blocking.blocks?(integration, entry)

  defp blocking?(_integration, _entry), do: true

  defp not_blocking,
    do: %{
      kind: :not_blocking,
      label: dgettext("dashboard_calendar", "Busy"),
      note: dgettext("dashboard_calendar", "This calendar doesn't block bookings")
    }

  defp busy,
    do: %{
      kind: :busy,
      label: dgettext("dashboard_calendar", "Busy"),
      note: dgettext("dashboard_calendar", "Guests can't book this time")
    }

  defp free,
    do: %{
      kind: :free,
      label: dgettext("dashboard_calendar", "Free"),
      note: dgettext("dashboard_calendar", "Guests can book this time")
    }

  defp sync_note(%{preview_of: %{}}, _integration),
    do: elem(CalendarEditMessages.refusal({:error, :syncing}), 1)

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

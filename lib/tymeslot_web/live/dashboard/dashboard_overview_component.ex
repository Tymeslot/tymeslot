defmodule TymeslotWeb.Dashboard.DashboardOverviewComponent do
  @moduledoc """
  LiveView component for the dashboard overview.

  Renders the onboarding checklist and the live agenda — a *focus cockpit* for
  the next appointment (with a live countdown and a self-arming Join button) over
  a *day spine*: a vertical time-rail where free stretches are compressed into
  labelled connectors and a pulsing now-line marks the present. Tomorrow follows
  as a compact peek. Bookings and synced calendar events are merged into one
  source-agnostic view upstream (`Tymeslot.Agenda`); here we only present it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda
  alias Tymeslot.Agenda.Day
  alias Tymeslot.Agenda.Entry
  # Aliased to disambiguate from the stdlib `Calendar` module.
  alias Tymeslot.Integrations.Calendar, as: CalendarContext
  alias TymeslotWeb.Dashboard.AgendaTimeline
  alias TymeslotWeb.Dashboard.DashboardOverview.ComponentView

  import TymeslotWeb.Dashboard.DashboardOverviewFormatters

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    agenda = get_in(assigns, [:shared_data, :agenda]) || %Day{}

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:agenda, agenda)
     # Survive the 60s agenda tick: a re-render must not close a modal the user
     # has open, so keep any already-selected entry rather than resetting it.
     |> assign_new(:selected_entry, fn -> nil end)
     |> assign_agenda_view(agenda, DateTime.utc_now())}
  end

  @impl Phoenix.LiveComponent
  def handle_event("open_entry", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_entry, find_entry(socket.assigns.agenda, id))}
  end

  def handle_event("close_entry", _params, socket) do
    {:noreply, assign(socket, :selected_entry, nil)}
  end

  def handle_event("set_entry_colour", %{"colour" => colour, "target" => target}, socket) do
    case decode_target(target) do
      :error ->
        {:noreply, socket}

      decoded ->
        case CalendarContext.set_event_colour(socket.assigns.current_user.id, decoded, colour) do
          {:ok, _override} ->
            {:noreply, reload_agenda_colours(socket)}

          {:error, _changeset} ->
            {:noreply,
             Flash.put_flash(
               socket,
               :error,
               dgettext("dashboard_home", "Couldn't save that colour. Please try again.")
             )}
        end
    end
  end

  def handle_event("clear_entry_colour", %{"target" => target}, socket) do
    case decode_target(target) do
      :error ->
        {:noreply, socket}

      decoded ->
        CalendarContext.clear_event_colour(socket.assigns.current_user.id, decoded)
        {:noreply, reload_agenda_colours(socket)}
    end
  end

  # Rebuilds the agenda from the database (now reflecting the override) and keeps
  # the detail modal open on the same entry so its picker shows the new colour.
  defp reload_agenda_colours(socket) do
    agenda = Agenda.day_agenda(socket.assigns.current_user, socket.assigns.agenda.timezone)

    selected =
      socket.assigns.selected_entry && find_entry(agenda, socket.assigns.selected_entry.id)

    socket
    |> assign(:agenda, agenda)
    |> assign(:selected_entry, selected)
    |> assign_agenda_view(agenda, DateTime.utc_now())
  end

  defp decode_target("meeting:" <> id), do: {:meeting, id}

  defp decode_target("external:" <> rest) do
    with [integration_id, uid] <- String.split(rest, ":", parts: 2),
         {parsed_id, ""} <- Integer.parse(integration_id) do
      {:external, parsed_id, uid}
    else
      _other -> :error
    end
  end

  defp decode_target(_other), do: :error

  defp find_entry(%Day{} = agenda, id) do
    [agenda.next | agenda.today ++ agenda.tomorrow]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&(&1.id == id))
  end

  # Reshapes the domain agenda into the view model the rail renders against. The
  # domain pops the hero out of its day group; here we fold it back in so the
  # spine shows where "next" actually sits, and mark it by id for the cockpit.
  defp assign_agenda_view(socket, %Day{} = agenda, now) do
    today = local_date(now, agenda.timezone)
    next_id = agenda.next && agenda.next.id

    {all_day_today, timed_today} =
      agenda |> entries_on(today) |> Enum.split_with(& &1.all_day?)

    others = Enum.reject(timed_today, &(&1.id == next_id))

    assign(socket,
      now: now,
      all_day_today: all_day_today,
      spine: AgendaTimeline.spine(timed_today, now, next_id),
      today_count: length(all_day_today) + length(timed_today),
      then_entry: List.first(others),
      more_count: max(length(others) - 1, 0),
      # The cockpit already features `next`; keep it out of the peek so a
      # tomorrow-only hero isn't listed twice.
      tomorrow_entries:
        agenda |> entries_on(Date.add(today, 1)) |> Enum.reject(&(&1.id == next_id))
    )
  end

  # All entries occupying `date` (by overlap), hero folded back in, de-duplicated
  # and ordered — so a multi-day block or an in-progress overnight entry appears
  # on the day being viewed, not only the day it began.
  defp entries_on(%Day{} = agenda, date) do
    [agenda.next | agenda.today ++ agenda.tomorrow]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&Entry.covers?(&1, date, agenda.timezone))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.start_at, DateTime)
  end

  @impl Phoenix.LiveComponent
  def render(assigns), do: ComponentView.agenda(assigns)
end

defmodule TymeslotWeb.Dashboard.Availability.ExtraAvailabilityCard do
  @moduledoc """
  Card for a schedule's extra available times
  (`Tymeslot.Availability.ExtraAvailability`): dates with a from and a to
  time, open besides the weekly hours.

  It sits inside the schedule panel, unlike time off, because the times
  belong to the selected schedule and reach only the meeting types booked
  against it. Adding is a row of three inputs in the card itself; each time
  in the list removes with one click. Past dates are never listed: the daily
  retention run deletes them.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Availability.{ExtraAvailability, TimeOff}
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn -> blank_form() end)
     |> assign_new(:error, fn -> nil end)
     |> load()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :days, Enum.chunk_by(assigns.extras, & &1.date))

    ~H"""
    <div>
      <.card
        icon="hero-calendar-days"
        title={dgettext("dashboard_availability", "Extra available times")}
        description={
          dgettext(
            "dashboard_availability",
            "Dates you can be booked besides your weekly hours, such as office hours once a month. With every weekday switched off, only these are offered. They apply to the meeting types using this schedule; past dates are removed automatically."
          )
        }
      >
        <form
          id={"extra-availability-form-#{@schedule.id}"}
          phx-submit="add_extra"
          phx-target={@myself}
          class="flex flex-wrap items-end gap-3"
          data-testid="extra-availability-form"
        >
          <.input
            type="date"
            name="extra[date]"
            label={dgettext("dashboard_availability", "Date")}
            value={@form["date"]}
            min={Date.to_iso8601(@today)}
            required
          />
          <.input
            type="time"
            name="extra[start_time]"
            label={dgettext("dashboard_availability", "From")}
            value={@form["start_time"]}
            required
          />
          <.input
            type="time"
            name="extra[end_time]"
            label={dgettext("dashboard_availability", "To")}
            value={@form["end_time"]}
            required
          />
          <.action_button type="submit" icon="hero-plus" data-testid="extra-availability-add">
            {dgettext("dashboard_availability", "Add")}
          </.action_button>
        </form>
        <p :if={@error} class="form-error mt-2" data-testid="extra-availability-error">{@error}</p>

        <p :if={@extras == []} class="mt-4 text-token-sm text-tymeslot-500 italic">
          {dgettext("dashboard_availability", "No extra times added.")}
        </p>

        <ul :if={@extras != []} class="mt-4 space-y-2" data-testid="extra-availability-list">
          <li
            :for={[first | _] = day <- @days}
            class="flex flex-wrap items-center gap-2"
            data-testid="extra-availability-day"
          >
            <span class="text-token-sm font-medium text-tymeslot-800 min-w-[10rem]">
              {LocalizationHelpers.format_date(first.date)}
            </span>
            <span
              :for={extra <- day}
              class="tag-semantic tag-semantic-turquoise"
              data-testid="extra-availability-time"
            >
              {time_range(extra, @time_format)}
              <button
                type="button"
                phx-click="delete_extra"
                phx-value-id={extra.id}
                phx-target={@myself}
                class="inline-flex items-center justify-center rounded-token-full border border-turquoise-200 bg-white text-turquoise-600 hover:text-turquoise-700 hover:border-turquoise-300"
                aria-label={dgettext("dashboard_availability", "Remove this time")}
                data-testid="extra-availability-remove"
              >
                <.icon name="hero-x-mark" class="h-4 w-4" />
              </button>
            </span>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_extra", %{"extra" => params}, socket) do
    %{schedule: schedule, today: today} = socket.assigns

    case ExtraAvailability.add(schedule, parse(params), today) do
      {:ok, _extra} ->
        Flash.info(dgettext("dashboard_availability", "Extra time added"))
        {:noreply, socket |> assign(form: blank_form(), error: nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, form: params, error: error_message(reason))}
    end
  end

  def handle_event("delete_extra", %{"id" => id}, socket) do
    case ExtraAvailability.delete(socket.assigns.schedule, id) do
      {:ok, _deleted} -> Flash.info(dgettext("dashboard_availability", "Extra time removed"))
      {:error, _reason} -> :ok
    end

    {:noreply, load(socket)}
  end

  defp load(socket) do
    today = TimeOff.today(socket.assigns.profile.timezone)

    assign(socket,
      today: today,
      extras: ExtraAvailability.list_upcoming(socket.assigns.schedule.id, today)
    )
  end

  defp blank_form, do: %{"date" => "", "start_time" => "", "end_time" => ""}

  defp parse(params) do
    %{
      date: parse_date(params["date"]),
      start_time: parse_time(params["start_time"]),
      end_time: parse_time(params["end_time"])
    }
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_time(value) when is_binary(value) and byte_size(value) == 5,
    do: parse_time(value <> ":00")

  defp parse_time(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> time
      {:error, _reason} -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp time_range(extra, time_format) do
    dgettext("dashboard_availability", "%{from}–%{to}",
      from: TimeFormat.format(extra.start_time, time_format),
      to: TimeFormat.format(extra.end_time, time_format)
    )
  end

  defp error_message(:in_past),
    do: dgettext("dashboard_availability", "The date must be today or later.")

  defp error_message(:overlap),
    do: dgettext("dashboard_availability", "This time overlaps another extra time on that date.")

  defp error_message(:too_many),
    do:
      dgettext("dashboard_availability", "A schedule can hold up to %{count} extra times.",
        count: ExtraAvailability.max_per_schedule()
      )

  defp error_message(%Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :end_time) or
         Keyword.has_key?(changeset.errors, :start_time),
       do: dgettext("dashboard_availability", "Enter a from time before the to time."),
       else: dgettext("dashboard_availability", "Enter a date, a from and a to time.")
  end
end

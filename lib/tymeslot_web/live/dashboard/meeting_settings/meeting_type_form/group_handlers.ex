defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupHandlers do
  @moduledoc """
  The group bookings section's events for `MeetingTypeForm`: turning group
  bookings on and off, the participant limit, and the seat-availability and
  last-spots display options.

  Split out of the form to keep it inside the size limit.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.InputValidation
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{
    Autosave,
    GroupRules,
    Init,
    SessionHandlers,
    Validation
  }

  @events ~w(toggle_group_bookings change_max_participants toggle_seat_availability
             toggle_last_spots change_last_spots_threshold)

  @doc "The events handled here, for the form to route to `handle_event/3`."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Applies one of `events/0` to the form's socket."
  @spec handle_event(String.t(), map(), Socket.t()) :: Socket.t()
  def handle_event("toggle_group_bookings", _params, socket) do
    # Guard: turning group bookings on is refused while anything stands in
    # the way (`GroupRules.enable_blocker/1`: no plan access, payment or
    # approval required, a location that is not fixed in advance). The
    # control renders disabled with the reason, so this only stops a stale
    # or forged event. Turning them off is refused only while planned dates
    # hold a fixed-date type on (`SessionHandlers.dates_planned?/1`).
    #
    # A host who has lost charge capability cannot reach the payments toggle,
    # so a required payment does not block them; enabling clears
    # `payment_required` instead, keeping the two mutually exclusive without
    # a dead end.
    turning_on? = not socket.assigns.group_bookings_enabled

    if (turning_on? and GroupRules.enable_blocker(socket.assigns) == nil) or
         (not turning_on? and not SessionHandlers.dates_planned?(socket.assigns)) do
      socket
      |> assign(:group_bookings_enabled, !socket.assigns.group_bookings_enabled)
      |> assign(:payment_required, false)
      |> Validation.clear_error(:max_participants)
      |> Autosave.maybe_run()
    else
      socket
    end
  end

  def handle_event(
        "change_max_participants",
        %{"meeting_type" => %{"max_participants_input" => value}},
        socket
      ) do
    metadata = Helpers.get_security_metadata(socket)

    case InputValidation.validate_field(:group_participants, value, metadata) do
      {:ok, sanitized} ->
        socket
        |> assign(:max_participants, sanitized)
        |> Validation.clear_error(:max_participants)
        |> Autosave.maybe_run()

      {:error, %{max_participants: message}} ->
        # Keep the raw value so the input shows what was typed; skip the
        # autosave — persisting a known-invalid limit is pointless. The
        # indicator must not keep claiming the form is saved meanwhile.
        socket
        |> assign(:max_participants, value)
        |> assign(:save_status, :unsaved)
        |> assign(
          :form_errors,
          Map.put(socket.assigns.form_errors, :max_participants, message)
        )
    end
  end

  def handle_event("toggle_seat_availability", _params, socket) do
    socket
    |> assign(:show_seat_availability, !socket.assigns.show_seat_availability)
    |> Autosave.maybe_run()
  end

  def handle_event("toggle_last_spots", _params, socket) do
    threshold = if is_nil(socket.assigns.last_spots_threshold), do: Init.default_last_spots()

    socket
    |> assign(:last_spots_threshold, threshold)
    |> Autosave.maybe_run()
  end

  # The input is bounded by its own min and max, so a value outside them is
  # clamped rather than refused, and one that is not a number is ignored.
  def handle_event(
        "change_last_spots_threshold",
        %{"meeting_type" => %{"last_spots_threshold_input" => value}},
        socket
      ) do
    case Integer.parse(value) do
      {count, ""} ->
        range = Constraints.last_spots_threshold_range()

        socket
        |> assign(:last_spots_threshold, count |> max(range.first) |> min(range.last))
        |> Autosave.maybe_run()

      _not_a_number ->
        socket
    end
  end
end

defmodule TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType do
  @moduledoc """
  The meeting type the booking is for: the booker's choice of duration
  (`select_duration`), resolved to the organiser's meeting type.

  Known once the chosen duration is one the organiser offers, or once a type
  is resolved on the socket (a direct link, a reschedule). Moving on needs
  the former, as the overview's Next always has. "Back" returns to a moment
  collecting it only for a booker who came through the overview: a direct or
  private link must never show the organiser's other types. `default/2`
  settles it without asking, on the organiser's first or shortest type.
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 2]

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry
  alias TymeslotWeb.Themes.Shared.ReschedulePin

  @strategies [:first, :shortest]

  @impl Fact
  def key, do: :meeting_type

  @impl Fact
  def requires(_assigns), do: []

  @impl Fact
  def required?(_assigns), do: true

  # A resolved type counts on its own: a demo organiser's types are
  # synthesised rather than stored, so the duration is the one test every
  # page can answer, and a slug link resolves the type without a duration
  # check ever running.
  @impl Fact
  def known?(assigns), do: not is_nil(assigns[:meeting_type]) or selection(assigns) == :ok

  @impl Fact
  def events, do: [:select_duration]

  # A pinned reschedule has no choice of type to make, so the payload is
  # ignored rather than trusted; `ReschedulePin` says why that matters even
  # though no second card is rendered to click.
  @impl Fact
  def handle(socket, :select_duration, data) do
    duration = ReschedulePin.selected_duration(socket, data)

    socket =
      socket
      |> assign(selected_duration: duration, duration: duration)
      |> StepEntry.maybe_assign_meeting_type(duration)
      # Trigger availability refresh when duration changes
      |> AvailabilityHelpers.fetch_month_availability_async()

    {:noreply, socket}
  end

  @impl Fact
  def continue(socket) do
    case selection(socket.assigns) do
      :ok -> {:done, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a booker who entered through the overview may return to it. A
  # direct or private-link entry sets `entered_via_overview: false` and must
  # never expose the organiser's other meeting types; checked here, server
  # side, so a client cannot bypass the template's `:if` guard by pushing
  # `back_step` itself.
  @impl Fact
  def revisitable?(assigns), do: assigns[:entered_via_overview] == true

  @impl Fact
  def default_strategies, do: @strategies

  @impl Fact
  def default(socket, strategy) when strategy in @strategies do
    with false <- known?(socket.assigns),
         %{} = meeting_type <- pick(socket.assigns[:meeting_types] || [], strategy) do
      {:noreply, socket} =
        handle(socket, :select_duration, MeetingTypes.effective_slug(meeting_type))

      socket
    else
      _known_or_none -> socket
    end
  end

  defp pick([], _strategy), do: nil
  defp pick([first | _rest], :first), do: first
  defp pick(meeting_types, :shortest), do: Enum.min_by(meeting_types, & &1.duration_minutes)

  defp selection(assigns),
    do:
      MeetingTypes.validate_duration_selection(
        assigns[:selected_duration],
        validatable_meeting_types(assigns)
      )

  # The booker's selection is authoritative once resolved. A private type is
  # reached by its direct link and is absent from the public `:meeting_types`
  # list, so include the resolved `:meeting_type` to validate against.
  defp validatable_meeting_types(assigns) do
    list = assigns[:meeting_types] || []

    case assigns[:meeting_type] do
      nil -> list
      meeting_type -> [meeting_type | list]
    end
  end
end

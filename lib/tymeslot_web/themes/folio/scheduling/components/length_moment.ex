defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.LengthMoment do
  @moduledoc """
  The length, which opens below the ways to work once a meeting type that
  offers several lengths is chosen (`Tymeslot.MeetingTypes.Lengths`); the
  navigator passes it over for every other type and for a reschedule, which
  keeps the booked length. A heading, then each length as an entry of the
  ways-to-work list, a button for the length fact (`data-fact="length"`,
  `aria-current` on the chosen one). Choosing one opens the calendar below
  by itself; the list stays, so another choice reopens the calendar for it.
  The entries keep the test ids Quill's and Rhythm's length steps carry:
  `length-step` on the section, `length-option` with `data-minutes` on each
  entry.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.Lengths
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    meeting_type = assigns[:meeting_type]
    chosen = assigns[:chosen_length_minutes]

    assigns =
      assign(assigns,
        offered: Lengths.offered(meeting_type),
        chosen: if(Lengths.offers?(meeting_type, chosen), do: chosen)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="folio-section folio-length booker-card"
      data-testid="length-step"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
        class="folio-section__title"
      >
        {dgettext("booking", "How long should the meeting be?")}
      </JourneyComponents.moment_heading>

      <ul class="folio-meetings">
        <li :for={minutes <- @offered}>
          <button
            type="button"
            class="folio-meeting"
            phx-click="select_length"
            phx-value-minutes={minutes}
            phx-target={@myself}
            data-testid="length-option"
            data-minutes={minutes}
            data-fact="length"
            data-value={minutes}
            aria-current={if @chosen == minutes, do: "true"}
          >
            <span class="folio-meeting__name">{LocalizationHelpers.format_duration(minutes)}</span>
          </button>
        </li>
      </ul>
    </section>
    """
  end
end

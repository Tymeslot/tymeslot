defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.SeriesMoment do
  @moduledoc """
  The series (`Journey.Facts.Series`), which opens below the calendar once
  a time is picked for a meeting type that offers a series; the navigator
  passes it over for every other type and for a reschedule. The time
  picked is the first session.

  A section like the others on the page: a heading, the meeting and its
  length, then the shared series body (`SeriesChooser`): the rhythm and
  the session count of a recurring series, or the picker of further
  sessions of a flexible one, every session with how it stands, the
  notices and a paid series' total. There is no Next: once every session is
  available the details open below by itself, and until then the line
  under the list says why they have not. Another time picked above remakes
  the series from it (`Series.refresh/1`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.SeriesChooser
  alias TymeslotWeb.Themes.Shared.StepEvents

  # The time picked, in the calendar's section above: where the clash
  # notice's "Change time" takes the focus.
  @chosen_time "#when-step .slot-list__slot--selected"

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :change_time, JS.focus(to: @chosen_time))

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="folio-section folio-series booker-card"
      data-testid="series-step"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <header class="folio-section__header">
        <JourneyComponents.moment_heading
          moment={@moment}
          moment_state={@moment_state}
          focus={assigns[:journey_focus]}
          class="folio-section__title"
        >
          {SeriesChooser.heading(@meeting_type)}
        </JourneyComponents.moment_heading>
        <p class="folio-muted" data-testid="chosen-meeting-type">
          {@meeting_type && @meeting_type.name} · {BookingText.duration_label(assigns)}
        </p>
      </header>

      <SeriesChooser.chooser {assigns} target={@myself} change_time={@change_time} />

      <SeriesChooser.next_hint {assigns} />
    </section>
    """
  end
end

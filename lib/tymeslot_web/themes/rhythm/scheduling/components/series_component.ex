defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.SeriesComponent do
  @moduledoc """
  Rhythm's series slide (`Journey.Facts.Series`), shown after the time when
  the meeting type offers a series; the time picked is the first session.

  The slide's heading names the series, the line under it the meeting and
  its length; then the shared series body (`SeriesChooser`): the rhythm
  and the session count of a recurring series, or the picker of further
  sessions of a flexible one, every session with how it stands, the
  notices and a paid series' total. Next is offered once every session is
  available, with the reason underneath until then.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.SeriesChooser
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :can_continue?, SeriesChooser.can_continue?(assigns))

    ~H"""
    <div
      class="scheduling-box booker-card"
      data-locale={@locale}
      data-testid="series-step"
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <div class="slide-container">
        <div class="slide slide--enter active">
          <div class="slide-content series-slide">
            <JourneyComponents.moment_heading
              tag="h1"
              moment={assigns[:moment]}
              moment_state={assigns[:moment_state]}
              focus={assigns[:journey_focus]}
              class="slide-title"
            >
              {SeriesChooser.heading(@meeting_type)}
            </JourneyComponents.moment_heading>
            <p class="organizer-instruction" data-testid="chosen-meeting-type">
              {@meeting_type && @meeting_type.name} · {BookingText.duration_label(assigns)}
            </p>

            <SeriesChooser.chooser {assigns} target={@myself} />

            <div class="slide-actions horizontal">
              <button
                type="button"
                class="prev-button"
                phx-click="back_step"
                phx-target={@myself}
                data-testid="back-step"
                data-intent="back"
              >
                <.icon name="hero-arrow-left" class="inline-icon" />
                {dgettext("booking", "Back")}
              </button>
              <button
                type="button"
                class={["next-button", not @can_continue? && "disabled"]}
                phx-click="next_step"
                phx-target={@myself}
                data-testid="next-step"
                data-intent="continue"
                disabled={not @can_continue?}
                aria-describedby={SeriesChooser.next_hint_describedby(assigns)}
              >
                {dgettext("booking", "Next")}
                <.icon name="hero-arrow-right" class="inline-icon" />
              </button>
            </div>
            <SeriesChooser.next_hint {assigns} />
          </div>
        </div>
      </div>
    </div>
    """
  end
end

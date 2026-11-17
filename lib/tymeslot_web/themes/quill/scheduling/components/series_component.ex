defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.SeriesComponent do
  @moduledoc """
  Quill theme step for booking a series (`Journey.Facts.Series`), shown
  after the time when the meeting type offers one. The time picked is the
  first session.

  A recurring series names its rhythm and lets the booker set how many
  sessions it has; a flexible one lets the booker add sessions at other
  offered times. Either way every session is listed with how it stands,
  and the booker moves on once all of them can be booked. Where the type
  also takes a single session, a link books just the time picked.

  It belongs to the second step of the indicator, "Date & Time".
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.SeriesChooser
  alias TymeslotWeb.Themes.Shared.StepEvents
  use TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        navigable_steps: Runtime.navigable_steps(assigns),
        step_numbers: Runtime.step_numbers(assigns),
        can_continue?: SeriesChooser.can_continue?(assigns)
      )

    ~H"""
    <div
      class="container quill-container flex-1"
      data-locale={@locale}
      data-testid="series-step"
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <.page_layout
        show_steps={true}
        navigable_steps={@navigable_steps}
        step_numbers={@step_numbers}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="overview-content-area flex items-start justify-center">
          <div class="w-full">
            <.glass_morphism_card class="booker-card series-card" data-testid="booker-card">
              <div class="overview-card-body">
                <JourneyComponents.moment_heading
                  tag="h1"
                  moment={assigns[:moment]}
                  moment_state={assigns[:moment_state]}
                  focus={assigns[:journey_focus]}
                  class="section-header overview-title"
                >
                  {SeriesChooser.heading(@meeting_type)}
                </JourneyComponents.moment_heading>
                <p class="overview-description text-glass-primary" data-testid="chosen-meeting-type">
                  {@meeting_type && @meeting_type.name} · {BookingText.duration_label(assigns)}
                </p>

                <SeriesChooser.chooser {assigns} target={@myself} />

                <div class="schedule-actions overview-next-action animate-fade-in-up">
                  <.action_button
                    type="button"
                    phx-click="back_step"
                    phx-target={@myself}
                    data-testid="back-step"
                    data-intent="back"
                    variant={:secondary}
                    class="flex-1 gap-2"
                  >
                    <.icon name="hero-arrow-left" class="inline-icon" />
                    {dgettext("booking", "Back")}
                  </.action_button>
                  <.action_button
                    phx-click="next_step"
                    phx-target={@myself}
                    data-testid="next-step"
                    data-intent="continue"
                    disabled={not @can_continue?}
                    aria-describedby={SeriesChooser.next_hint_describedby(assigns)}
                    class="flex-1 gap-2"
                  >
                    {dgettext("booking", "Next")}
                    <.icon name="hero-arrow-right" class="inline-icon" />
                  </.action_button>
                </div>
                <SeriesChooser.next_hint {assigns} />
              </div>
            </.glass_morphism_card>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end
end

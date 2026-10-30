defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.LengthComponent do
  @moduledoc """
  Paper's length screen, between the meeting types and the schedule screen,
  shown only for a meeting type that offers several lengths
  (`Tymeslot.MeetingTypes.Lengths`); `Navigators.Paged` passes it over for
  every other type and for a reschedule, which keeps the booked length.

  It is the overview's wide card and two-pane frame: the meeting type's name
  and the question on the left, the lengths as the overview's bordered list
  on the right. Choosing a length goes straight on to the schedule screen,
  as choosing a meeting type does (`select_length`, then `next_step`); back
  there, the length the visitor chose stays marked (`aria-current`). Back,
  shown to a visitor who came through the overview, heads the card and
  returns to the meeting types. The rows keep the test ids Quill's and
  Rhythm's length steps carry: `length-step` on the card, `length-option`
  with `data-minutes` on each row.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.Lengths
  alias TymeslotWeb.Themes.Paper.Components
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
        chosen: if(Lengths.offers?(meeting_type, chosen), do: chosen),
        show_back: assigns[:entered_via_overview] == true
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="paper-card paper-card--wide booker-card"
      data-locale={@locale}
      data-testid="length-step"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <div :if={@show_back} class="paper-topbar">
        <button
          type="button"
          class="paper-button paper-button--quiet paper-topbar__back"
          phx-click="back_step"
          phx-target={@myself}
          data-testid="back-step"
          data-intent="back"
        >
          <.icon name="hero-arrow-left-mini" class="paper-button__icon" />
          {dgettext("booking", "Back")}
        </button>
      </div>

      <Components.brand theme_tokens={@theme_tokens} />

      <div class="paper-overview">
        <header class="paper-intro">
          <h1 class="paper-title">{@meeting_type && @meeting_type.name}</h1>
          <p class="paper-intro__instruction">
            {dgettext("booking", "How long should the meeting be?")}
          </p>
        </header>

        <div class="paper-choices">
          <ul class="paper-types" role="list">
            <li :for={minutes <- @offered} class="paper-types__item">
              <button
                type="button"
                class="paper-type"
                phx-click={choose(minutes, @myself)}
                data-testid="length-option"
                data-minutes={minutes}
                data-fact="length"
                data-value={minutes}
                aria-current={if @chosen == minutes, do: "true"}
              >
                <span class="paper-type__main">
                  <span class="paper-type__name">
                    {LocalizationHelpers.format_duration(minutes)}
                  </span>
                </span>
                <.icon name="hero-chevron-right-mini" class="paper-type__chevron" />
              </button>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  # A row's click: the length, then the way on, as a meeting type's row
  # goes straight on (`choose_duration`).
  defp choose(minutes, target) do
    "select_length"
    |> JS.push(value: %{minutes: minutes}, target: target)
    |> JS.push("next_step", target: target)
  end
end

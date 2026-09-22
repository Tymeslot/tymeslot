defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.LengthComponent do
  @moduledoc """
  Rhythm theme slide for choosing how long the meeting should be.

  Shown after the meeting type when that type offers more than one length
  (`Tymeslot.MeetingTypes.Lengths`), in the style of the meeting type cards.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.Lengths
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_length", %{"minutes" => minutes}, socket) do
    send(self(), {:step_event, :length, :select_length, minutes})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_slide", _params, socket) do
    send(self(), {:step_event, :length, :next_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("prev_slide", _params, socket) do
    send(self(), {:step_event, :length, :back_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assigns
      |> assign(:offered, Lengths.offered(assigns[:meeting_type]))
      |> assign(
        :chosen,
        if(Lengths.offers?(assigns[:meeting_type], assigns[:chosen_length_minutes]),
          do: assigns[:chosen_length_minutes]
        )
      )

    ~H"""
    <div class="scheduling-box" data-locale={@locale} data-testid="length-step">
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content">
            <h1 class="slide-title">
              {@meeting_type && @meeting_type.name}
            </h1>
            <p class="organizer-instruction">
              {dgettext("booking", "How long should the meeting be?")}
            </p>

            <div class="duration-grid">
              <div
                :for={minutes <- @offered}
                class={"duration-card #{if @chosen == minutes, do: "selected", else: ""}"}
              >
                <button
                  type="button"
                  phx-click="select_length"
                  phx-value-minutes={minutes}
                  phx-target={@myself}
                  class="duration-button"
                  data-testid="length-option"
                  data-minutes={minutes}
                  aria-pressed={to_string(@chosen == minutes)}
                >
                  <div class="duration-icon shrink-0">
                    <.icon name="hero-clock" class="hero-icon hero-icon--md" />
                  </div>
                  <div class="duration-info">
                    <div class="duration-name">
                      {LocalizationHelpers.format_duration(minutes)}
                    </div>
                  </div>
                </button>
              </div>
            </div>

            <div class="slide-actions horizontal">
              <button
                :if={@entered_via_overview}
                type="button"
                class="prev-button"
                phx-click="prev_slide"
                phx-target={@myself}
                data-testid="back-step"
              >
                ← {dgettext("booking", "back")}
              </button>
              <button
                type="button"
                class={if is_nil(@chosen), do: "next-button disabled", else: "next-button"}
                phx-click="next_slide"
                phx-target={@myself}
                data-testid="next-step"
                disabled={is_nil(@chosen)}
              >
                {dgettext("booking", "next")} →
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end

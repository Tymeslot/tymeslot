defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.LengthComponent do
  @moduledoc """
  Quill theme step for choosing how long the meeting should be.

  Shown after the meeting type when that type offers more than one length
  (`Tymeslot.MeetingTypes.Lengths`). It belongs to the first step of the
  indicator, which is labelled "Duration".
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.Lengths
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  import TymeslotWeb.Components.CoreComponents

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
  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, :length, :next_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("back_step", _params, socket) do
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
    <div class="container flex-1" data-locale={@locale} data-testid="length-step">
      <.page_layout
        show_steps={true}
        current_step={1}
        slug={assigns[:selected_duration]}
        username_context={@username_context}
      >
        <div class="overview-content-area flex items-start justify-center">
          <div class="w-full">
            <.glass_morphism_card>
              <div class="overview-card-body">
                <h1 class="section-header overview-title">
                  {@meeting_type && @meeting_type.name}
                </h1>
                <p class="overview-description text-glass-primary">
                  {dgettext("booking", "How long should the meeting be?")}
                </p>

                <%!-- Its own list class: the overview's width tiers key on
                      `.overview-duration-list` card counts and would widen this
                      step past every other one. --%>
                <div class="length-list">
                  <button
                    :for={minutes <- @offered}
                    type="button"
                    phx-click="select_length"
                    phx-value-minutes={minutes}
                    phx-target={@myself}
                    data-testid="length-option"
                    data-minutes={minutes}
                    aria-pressed={to_string(@chosen == minutes)}
                    class={"duration-card w-full rounded-xl cursor-pointer #{if @chosen == minutes, do: "duration-card--selected", else: "duration-card--unselected"}"}
                  >
                    <div class="flex items-center justify-between gap-2">
                      <h3 class="duration-card-title font-bold text-left">
                        {LocalizationHelpers.format_duration(minutes)}
                      </h3>
                      <.icon name="hero-clock" class="duration-card-icon text-white" />
                    </div>
                  </button>
                </div>

                <div class="schedule-actions overview-next-action animate-fade-in-up">
                  <.action_button
                    :if={@entered_via_overview}
                    type="button"
                    phx-click="back_step"
                    phx-target={@myself}
                    data-testid="back-step"
                    variant={:secondary}
                    class="flex-1"
                  >
                    ← {dgettext("booking", "back")}
                  </.action_button>
                  <.action_button
                    phx-click="next_step"
                    phx-target={@myself}
                    data-testid="next-step"
                    disabled={is_nil(@chosen)}
                    title={
                      if is_nil(@chosen),
                        do: dgettext("booking", "Please select a meeting duration first")
                    }
                    class="flex-1"
                  >
                    {dgettext("booking", "next")} →
                  </.action_button>
                </div>
              </div>
            </.glass_morphism_card>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end
end

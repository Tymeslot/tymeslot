defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Quill theme component for the overview/duration selection step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Demo
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_duration", %{"duration" => duration}, socket) do
    send(self(), {:step_event, :overview, :select_duration, duration})
    {:noreply, assign(socket, :selected_duration, duration)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, :overview, :next_step, nil})
    {:noreply, socket}
  end

  attr :duration, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :selected, :boolean, default: false
  attr :target, :any, default: nil

  defp duration_card(assigns) do
    ~H"""
    <button
      phx-click="select_duration"
      phx-value-duration={@duration}
      phx-target={@target}
      data-testid="duration-option"
      data-duration={@duration}
      class={"duration-card w-full rounded-xl cursor-pointer #{if @selected, do: "duration-card--selected", else: "duration-card--unselected"}"}
    >
      <div class="flex items-center justify-between">
        <div class="text-left flex-1">
          <div class="flex items-start justify-between gap-2 mb-1">
            <h3 class="duration-card-title font-bold flex-1">
              {@title}
            </h3>
            <span class="duration-card-badge inline-block px-2 py-0.5 text-xs font-semibold rounded-full whitespace-nowrap mt-1">
              {@badge || @duration}
            </span>
          </div>
          <p class="duration-card-description">
            {@description}
          </p>
        </div>
        <%= if @icon != "none" do %>
          <%= if String.starts_with?(@icon, "hero-") do %>
            <.icon name={sanitize_css_class(@icon)} class="duration-card-icon text-white" />
          <% else %>
            <div class="duration-card-emoji">{@icon}</div>
          <% end %>
        <% end %>
      </div>
    </button>
    """
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="container flex-1" data-locale={@locale}>
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
                <div class="overview-layout">
                  <div class="overview-avatar-section">
                    <div class="overview-avatar-wrapper relative inline-block">
                      <img
                        src={Demo.avatar_url(@organizer_profile)}
                        alt={Demo.avatar_alt_text(@organizer_profile)}
                        class="overview-avatar rounded-full object-cover shadow-2xl border-4 border-white/50 transition-all duration-300 hover:scale-105 cursor-pointer"
                      />
                      <div class="overview-success-badge absolute rounded-full flex items-center justify-center shadow-lg">
                        <span class="overview-success-badge-emoji text-white">✅</span>
                      </div>
                    </div>
                  </div>

                  <div>
                    <h1
                      class="section-header overview-title"
                    >
                      {gettext("Let's Connect!")}
                    </h1>
                    <p
                      class="overview-description text-glass-primary"
                    >
                      <%= if display_name = Profiles.display_name(@organizer_profile) do %>
                        {gettext("Hi, I'm %{name}. Select how much time you need for our conversation.", name: display_name)}
                      <% else %>
                        {gettext("Select how much time you need for our conversation.")}
                      <% end %>
                    </p>

                    <div class="overview-duration-list">
                      <%= cond do %>
                        <% @username_context && @meeting_types == [] -> %>
                          <div class="text-center py-8 text-purple-300">
                            <p class="text-lg font-medium">{gettext("No meeting types available")}</p>
                            <p class="text-sm mt-1">{gettext("Please contact the organizer")}</p>
                          </div>
                        <% @username_context && length(@meeting_types) > 0 -> %>
                          <%= for meeting_type <- @meeting_types do %>
                            <% slug = MeetingTypes.effective_slug(meeting_type) %>
                            <.duration_card
                              duration={slug}
                              title={meeting_type.name}
                              badge={LocalizationHelpers.format_duration(meeting_type.duration_minutes)}
                              description={meeting_type.description}
                              icon={meeting_type.icon || "hero-clock"}
                              selected={assigns[:selected_duration] == slug}
                              target={@myself}
                            />
                          <% end %>
                        <% true -> %>
                          <.duration_card
                            duration="15-minutes"
                            title={gettext("15 Minutes")}
                            badge={LocalizationHelpers.format_duration(15)}
                            description={gettext("Quick chat or brief consultation")}
                            icon="hero-bolt"
                            selected={assigns[:selected_duration] == "15-minutes"}
                            target={@myself}
                          />

                          <.duration_card
                            duration="30-minutes"
                            title={gettext("30 Minutes")}
                            badge={LocalizationHelpers.format_duration(30)}
                            description={gettext("In-depth discussion or detailed review")}
                            icon="hero-rocket-launch"
                            selected={assigns[:selected_duration] == "30-minutes"}
                            target={@myself}
                          />
                      <% end %>
                    </div>

                    <div class="overview-next-action animate-fade-in-up">
                      <.action_button
                        phx-click="next_step"
                        phx-target={@myself}
                        data-testid="next-step"
                        disabled={!assigns[:selected_duration]}
                        title={
                          unless assigns[:selected_duration],
                            do: gettext("Please select a meeting duration first")
                        }
                        class="w-full"
                      >
                        {gettext("next")} →
                      </.action_button>
                    </div>
                  </div>
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

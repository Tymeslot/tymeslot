defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Quill theme component for the overview/duration selection step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Demo.Resolver
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.MeetingComponents

  @impl true
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl true
  def handle_event("select_duration", %{"duration" => duration}, socket) do
    send(self(), {:step_event, :overview, :select_duration, duration})
    {:noreply, assign(socket, :selected_duration, duration)}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, :overview, :next_step, nil})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col">
      <.page_layout
        show_steps={true}
        current_step={1}
        duration={assigns[:selected_duration]}
        username_context={@username_context}
      >
        <div class="container flex-1 flex items-center justify-center px-4 py-2 md:py-8">
          <div class="w-full max-w-5xl">
            <.glass_morphism_card>
              <div class="p-3 sm:p-6 md:p-8 lg:p-10">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3 md:gap-8 items-center">
                  <div class="text-center md:text-left">
                    <div class="relative inline-block mx-auto md:mx-0">
                      <img
                        src={Resolver.avatar_url(@organizer_profile)}
                        alt={Resolver.avatar_alt_text(@organizer_profile)}
                        class="w-32 h-32 sm:w-48 sm:h-48 md:w-64 md:h-64 lg:w-80 lg:h-80 rounded-full object-cover shadow-2xl border-4 border-white/50 transition-all duration-300 hover:scale-105 cursor-pointer"
                      />
                      <div
                        class="absolute -bottom-2 -right-2 md:-bottom-4 md:-right-4 w-12 h-12 sm:w-16 sm:h-16 md:w-24 md:h-24 rounded-full flex items-center justify-center shadow-lg"
                        style="background: var(--glass-gradient-primary);"
                      >
                        <span class="text-white text-xl sm:text-2xl md:text-4xl">✅</span>
                      </div>
                    </div>
                  </div>

                  <div>
                    <h1
                      class="text-xl sm:text-2xl md:text-3xl lg:text-4xl font-bold mb-2 md:mb-4 text-center md:text-left"
                      style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
                    >
                      Let's Connect!
                    </h1>
                    <p
                      class="text-sm sm:text-base md:text-lg lg:text-xl mb-3 sm:mb-4 md:mb-6 text-center md:text-left"
                      style="color: rgba(255,255,255,0.9);"
                    >
                      <%= if display_name = Profiles.display_name(@organizer_profile) do %>
                        Hi, I'm {display_name}. Select how much time you need for our conversation.
                      <% else %>
                        Select how much time you need for our conversation.
                      <% end %>
                    </p>

                    <div class="space-y-2 md:space-y-4">
                      <%= cond do %>
                        <% @username_context && @meeting_types == [] -> %>
                          <!-- No meeting types available for this user -->
                          <div class="text-center py-8 text-purple-300">
                            <p class="text-lg font-medium">No meeting types available</p>
                            <p class="text-sm mt-1">Please contact the organizer</p>
                          </div>
                        <% @username_context && length(@meeting_types) > 0 -> %>
                          <!-- Show user's configured meeting types -->
                          <%= for meeting_type <- @meeting_types do %>
                            <.duration_card
                              duration={MeetingTypes.to_duration_string(meeting_type)}
                              title={meeting_type.name}
                              description={meeting_type.description}
                              icon={meeting_type.icon || "hero-clock"}
                              selected={
                                assigns[:selected_duration] ==
                                  MeetingTypes.to_duration_string(meeting_type)
                              }
                              target={@myself}
                            />
                          <% end %>
                        <% true -> %>
                          <!-- Default duration options (no username context) -->
                          <.duration_card
                            duration="15min"
                            title="15 Minutes"
                            description="Quick chat or brief consultation"
                            icon="hero-bolt"
                            selected={assigns[:selected_duration] == "15min"}
                            target={@myself}
                          />

                          <.duration_card
                            duration="30min"
                            title="30 Minutes"
                            description="In-depth discussion or detailed review"
                            icon="hero-rocket-launch"
                            selected={assigns[:selected_duration] == "30min"}
                            target={@myself}
                          />
                      <% end %>
                    </div>

                    <div class="mt-4 md:mt-8 animate-fade-in-up">
                      <.action_button
                        phx-click="next_step"
                        phx-target={@myself}
                        disabled={!assigns[:selected_duration]}
                        title={
                          unless assigns[:selected_duration],
                            do: "Please select a meeting duration first"
                        }
                        class="w-full"
                      >
                        Next Step →
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

defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Rhythm theme component for the overview/duration selection step.
  Extracted from the monolithic RhythmSlidesComponent to improve separation of concerns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles

  alias Tymeslot.Demo
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  @impl true
  def update(assigns, socket) do
    filtered_assigns = Map.drop(assigns, [:flash, :socket])

    # Sort meeting types alphabetically using natural sort (numbers compare numerically)
    sorted_meeting_types =
      case Map.get(filtered_assigns, :meeting_types) do
        list when is_list(list) -> Enum.sort_by(list, fn mt -> natural_key(meeting_title(mt)) end)
        _ -> Map.get(filtered_assigns, :meeting_types)
      end

    {:ok,
     socket
     |> assign(Map.put(filtered_assigns, :meeting_types, sorted_meeting_types))
     |> assign_new(:selected_duration, fn -> nil end)}
  end

  @impl true
  def handle_event("select_duration", %{"duration" => duration}, socket) do
    # duration is already a string like "30min" from the button
    new_duration =
      if socket.assigns[:selected_duration] == duration do
        nil
      else
        duration
      end

    send(self(), {:step_event, :overview, :select_duration, new_duration})
    {:noreply, assign(socket, :selected_duration, new_duration)}
  end

  @impl true
  def handle_event("next_slide", _params, socket) do
    send(self(), {:step_event, :overview, :next_step, nil})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="scheduling-box" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content overview-slide">
            <h1 class="slide-title">
              {gettext("Schedule with %{name}", name: display_name(@organizer_profile))}
            </h1>
            
    <!-- Organizer Profile -->
            <div class="organizer-profile">
              <div class="organizer-avatar">
                <img
                  src={Demo.avatar_url(@organizer_profile, :thumb)}
                  alt={Demo.avatar_alt_text(@organizer_profile)}
                  class="avatar-image"
                />
                <div class="avatar-checkmark">✓</div>
              </div>
              <div class="organizer-info">
                <p class="organizer-greeting">
                  {gettext("Hi! I'm %{name}.", name: display_name(@organizer_profile))}
                </p>
                <p class="organizer-instruction">
                  {gettext("Pick a meeting duration below.")}
                </p>
              </div>
            </div>
            
            <!-- Duration Selection -->
            <div class="duration-grid">
              <%= for meeting_type <- @meeting_types do %>
                <% slug = Tymeslot.MeetingTypes.to_slug(meeting_type) %>
                <div class={"duration-card #{if @selected_duration == slug, do: "selected", else: ""}"}>
                  <button
                    phx-click="select_duration"
                    phx-value-duration={slug}
                    phx-target={@myself}
                    class="duration-button"
                    data-testid="duration-option"
                    data-duration={slug}
                  >
                    <div class="duration-icon flex-shrink-0">
                      {render_icon(meeting_type.icon || get_default_icon(meeting_type))}
                    </div>
                    <div class="duration-info">
                      <div class="duration-name">
                        {meeting_type.name}
                      </div>
                      <div class="duration-time">
                        {LocalizationHelpers.format_duration(meeting_type.duration_minutes)}
                      </div>
                      <div class="duration-description">
                        {meeting_type.description}
                      </div>
                    </div>
                  </button>
                </div>
              <% end %>
            </div>
            
    <!-- Navigation -->
            <div class="slide-actions">
              <button
                class={get_next_button_class(@selected_duration)}
                phx-click="next_slide"
                phx-target={@myself}
                data-testid="next-step"
                disabled={is_nil(@selected_duration)}
              >
                {gettext("next")} →
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helpers
  defp display_name(profile) do
    Profiles.display_name(profile) || "there"
  end

  defp get_default_icon(meeting_type) do
    case meeting_type.duration_minutes do
      15 -> "hero-bolt"
      30 -> "hero-chat-bubble-left-right"
      60 -> "hero-hand-raised"
      90 -> "hero-chart-bar"
      120 -> "hero-flag"
      _ -> "hero-clock"
    end
  end

  defp render_icon(icon) do
    case icon do
      "none" ->
        ""

      "hero-" <> _ ->
        raw(
          "<span class='#{icon} hero-icon hero-icon--md'></span>"
        )

      _ ->
        raw(
          "<span class='hero-clock hero-icon hero-icon--md'></span>"
        )
    end
  end

  defp get_next_button_class(selected_duration) do
    if is_nil(selected_duration), do: "next-button disabled", else: "next-button"
  end

  # Natural sort key: split string into number and text segments and normalize
  defp natural_key(string) when is_binary(string) do
    normalized = String.downcase(String.trim(string))

    Enum.map(Regex.scan(~r/\d+|\D+/u, normalized), fn [seg] ->
      if String.match?(seg, ~r/^\d+$/) do
        {:num, String.to_integer(seg)}
      else
        {:str, seg}
      end
    end)
  end

  # Derive a robust meeting title for sorting: prefer name, fallback to duration
  defp meeting_title(%{name: name, duration_minutes: duration}) do
    trimmed =
      case name do
        n when is_binary(n) -> String.trim(n)
        _ -> ""
      end

    if trimmed != "" do
      trimmed
    else
      "#{duration} minutes"
    end
  end
end

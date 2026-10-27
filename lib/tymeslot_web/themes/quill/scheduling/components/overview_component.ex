defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Quill theme component for the overview/duration selection step.
  Features glassmorphism design with elegant transparency effects.

  Choosing a meeting type goes straight on to the schedule step
  (`choose_duration`); there is no Next.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Demo
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents
  use TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  attr :duration, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :selected, :boolean, default: false
  attr :requires_approval, :boolean, default: false
  attr :meeting_type, :any, default: nil
  attr :currency, :string, default: nil
  attr :show_price, :boolean, default: true
  attr :locale, :string, required: true
  attr :target, :any, default: nil

  defp duration_card(assigns) do
    ~H"""
    <button
      phx-click="choose_duration"
      phx-value-duration={@duration}
      phx-target={@target}
      data-testid="duration-option"
      data-duration={@duration}
      data-fact="meeting_type"
      data-value={@duration}
      class={"duration-card w-full rounded-xl cursor-pointer #{if @selected, do: "duration-card--selected", else: "duration-card--unselected"}"}
    >
      <%!-- The gap keeps the duration badge clear of the icon, which a range
            such as "15–120 min" would otherwise run into. --%>
      <div class="flex items-center justify-between gap-4">
        <div class="text-left flex-1">
          <div class="flex items-start justify-between gap-2 mb-1">
            <h3 class="duration-card-title font-bold flex-1">
              {@title}
              <ApprovalNotice.pill :if={@requires_approval} />
            </h3>
            <span class="duration-card-badge inline-block px-2 py-0.5 text-xs font-semibold rounded-full whitespace-nowrap mt-1">
              {@badge || @duration}
            </span>
          </div>
          <p class="duration-card-description">
            {@description}
          </p>
          <GroupSession.hint meeting_type={@meeting_type} />
          <MeetingPrice.hint
            :if={@show_price}
            meeting_type={@meeting_type}
            currency={@currency}
            locale={@locale}
          />
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
    profile = assigns.organizer_profile

    # Either line may be unsaid (`nil`), and then is not rendered at all.
    assigns =
      assign(assigns,
        greeting: BookingText.greeting(profile, Profiles.display_name(profile), :quill),
        instruction: BookingText.instruction(profile, :quill)
      )

    ~H"""
    <div
      class="container quill-container flex-1"
      data-locale={@locale}
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <.page_layout
        show_steps={true}
        current_step={1}
        slug={assigns[:selected_duration]}
        username_context={@username_context}
      >
        <div class="overview-content-area flex items-start justify-center">
          <div class="w-full">
            <.glass_morphism_card class="booker-card" data-testid="booker-card">
              <div class="overview-card-body">
                <div class="overview-layout">
                  <div class="overview-avatar-section">
                    <div class="overview-avatar-wrapper relative inline-block">
                      <img
                        src={Demo.avatar_url(@organizer_profile)}
                        alt={Demo.avatar_alt_text(@organizer_profile)}
                        class="overview-avatar rounded-full object-cover shadow-2xl border-4 border-white/50 transition-all duration-300 hover:scale-105 cursor-pointer"
                      />
                    </div>
                  </div>

                  <div>
                    <h1 class="section-header overview-title">
                      {BookingText.heading(
                        @organizer_profile,
                        :quill,
                        Profiles.display_name(@organizer_profile)
                      )}
                    </h1>
                    <%!-- Greeting and instruction are separate settings, often
                         separate thoughts; each starts on its own line, as the
                         Rhythm theme shows them. --%>
                    <p
                      :if={@greeting || @instruction}
                      class="overview-description text-glass-primary"
                    >
                      {@greeting}<br :if={@greeting && @instruction} />{@instruction}
                    </p>

                    <div class="overview-duration-list">
                      <%= if @meeting_types == [] do %>
                        <div class="text-center py-8 text-purple-300">
                          <p class="text-lg font-medium">
                            {dgettext("booking", "No meeting types available")}
                          </p>
                          <p class="text-sm mt-1">
                            {dgettext("booking", "Please contact the organiser")}
                          </p>
                        </div>
                      <% else %>
                        <%= for meeting_type <- @meeting_types do %>
                          <% slug = MeetingTypes.effective_slug(meeting_type) %>
                          <.duration_card
                            duration={slug}
                            title={meeting_type.name}
                            badge={LocalizationHelpers.format_length_badge(meeting_type)}
                            description={meeting_type.description}
                            icon={meeting_type.icon || "hero-clock"}
                            selected={assigns[:selected_duration] == slug}
                            requires_approval={Approval.required?(meeting_type)}
                            meeting_type={meeting_type}
                            currency={@host_currency}
                            show_price={!assigns[:is_rescheduling]}
                            locale={@locale}
                            target={@myself}
                          />
                        <% end %>
                      <% end %>
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

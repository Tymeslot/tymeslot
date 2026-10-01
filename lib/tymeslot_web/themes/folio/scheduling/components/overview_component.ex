defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Folio's overview: the full masthead (cover, portrait, name, headline and
  bio), then the meeting types as cards with their descriptions in full.

  The page's heading and instruction (the organiser's own wording, or the
  defaults) introduce the meeting types; the greeting line is not shown,
  since the name, headline and bio already introduce the organiser.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="folio-card folio-card--overview booker-card" data-locale={@locale}>
      <Masthead.masthead
        variant={:full}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
      />

      <div class="folio-card__body">
        <div class="folio-meetings-intro">
          <h2 class="folio-subtitle">
            {BookingText.heading(
              @organizer_profile,
              :folio,
              Profiles.display_name(@organizer_profile)
            )}
          </h2>
          <p class="folio-muted">{BookingText.instruction(@organizer_profile)}</p>
        </div>

        <%= if @meeting_types == [] do %>
          <div class="folio-empty">
            <p class="folio-empty__title">{dgettext("booking", "No meeting types available")}</p>
            <p class="folio-muted">{dgettext("booking", "Please contact the organiser")}</p>
          </div>
        <% else %>
          <ul class="folio-meetings">
            <%= for meeting_type <- @meeting_types do %>
              <% slug = MeetingTypes.effective_slug(meeting_type) %>
              <li>
                <button
                  type="button"
                  class="folio-meeting"
                  phx-click="select_duration"
                  phx-value-duration={slug}
                  phx-target={@myself}
                  data-testid="duration-option"
                  data-duration={slug}
                  aria-pressed={to_string(@selected_duration == slug)}
                >
                  <span class="folio-meeting__name">
                    {meeting_type.name}
                    <ApprovalNotice.pill :if={Approval.required?(meeting_type)} />
                  </span>
                  <span class="folio-meeting__duration">
                    {LocalizationHelpers.format_duration(meeting_type.duration_minutes)}
                  </span>
                  <span :if={present?(meeting_type.description)} class="folio-meeting__description">
                    {meeting_type.description}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        <% end %>

        <div class="folio-actions">
          <button
            type="button"
            class="folio-button folio-button--primary"
            phx-click="next_step"
            phx-target={@myself}
            data-testid="next-step"
            disabled={is_nil(@selected_duration)}
          >
            {dgettext("booking", "Next")}
            <.icon name="hero-arrow-right-mini" class="folio-button__icon" />
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp present?(text), do: is_binary(text) and String.trim(text) != ""
end

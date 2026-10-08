defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.OverviewStep do
  @moduledoc """
  The fixture theme's overview: the organiser's name, the shared heading in the
  rendering theme's voice, the organiser's headline and bio (the shared
  `ProfileIntro`), one button per meeting type, and a button sending the
  theme's own `theme:ping` event.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.ProfileIntro
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-overview">
      <h1>{Profiles.display_name(@organizer_profile)}</h1>
      <p data-testid="fixture-voice-heading">
        {BookingText.heading(
          @organizer_profile,
          theme_key(@theme_id),
          Profiles.display_name(@organizer_profile)
        )}
      </p>
      <ProfileIntro.headline profile={@organizer_profile} />
      <ProfileIntro.bio profile={@organizer_profile} />
      <img
        :if={@theme_tokens && @theme_tokens.media[:emblem]}
        src={@theme_tokens.media[:emblem]}
        alt=""
        data-testid="fixture-emblem"
      />
      <button
        :for={meeting_type <- @meeting_types}
        type="button"
        phx-click="select_duration"
        phx-value-duration={MeetingTypes.effective_slug(meeting_type)}
        phx-target={@myself}
        data-testid="duration-option"
        data-fact="meeting_type"
        data-value={MeetingTypes.effective_slug(meeting_type)}
        aria-pressed={to_string(@selected_duration == MeetingTypes.effective_slug(meeting_type))}
      >
        {meeting_type.name}
        <ApprovalNotice.pill :if={Approval.required?(meeting_type)} />
      </button>
      <button
        type="button"
        phx-click="next_step"
        phx-target={@myself}
        data-testid="next-step"
        data-intent="continue"
        disabled={is_nil(@selected_duration)}
      >
        Next
      </button>
      <button type="button" phx-click="theme:ping" phx-target={@myself} data-testid="fixture-ping">
        Ping
      </button>
      <p :if={assigns[:fixture_pinged]} data-testid="fixture-pinged">Pinged</p>
    </section>
    """
  end

  # The steps are shared by the fixture and the showcase theme, so each page
  # speaks for the theme it is rendering.
  defp theme_key(theme_id) do
    {:ok, key} = Catalog.id_to_key(theme_id)
    key
  end
end

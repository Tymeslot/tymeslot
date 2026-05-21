defmodule TymeslotWeb.Themes.Quill.Theme do
  @moduledoc """
  Quill theme implementation with glassmorphism design and 4-step flow.
  """

  @behaviour TymeslotWeb.Themes.Core.Behaviour

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Quill.Meeting.{Cancel, CancelConfirmed, Reschedule}

  @impl TymeslotWeb.Themes.Core.Behaviour
  def states do
    %{
      overview: %{step: 1, next: :schedule, prev: nil},
      schedule: %{step: 2, next: :booking, prev: :overview},
      booking: %{step: 3, next: :confirmation, prev: :schedule},
      confirmation: %{step: 4, prev: nil}
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def css_file, do: "/assets/scheduling-theme-quill.css"

  @impl TymeslotWeb.Themes.Core.Behaviour
  def components do
    %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def live_view_module do
    TymeslotWeb.Themes.Quill.Scheduling.Live
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def theme_config do
    %{
      name: "Quill",
      description:
        "Glass morphism design with elegant transparency effects and a 4-step booking flow.",
      preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
      flow_steps: 4,
      design_system: :glassmorphism,
      supports_duration_selection: true,
      supports_inline_booking: false
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def validate_theme do
    required_components = [:overview, :schedule, :booking, :confirmation]

    missing_components =
      Enum.filter(required_components, fn component ->
        not Code.ensure_loaded?(components()[component])
      end)

    if Enum.empty?(missing_components) do
      :ok
    else
      {:error, "Missing components: #{inspect(missing_components)}"}
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def initial_state_for_action(live_action) do
    case live_action do
      :index -> :overview
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def supports_feature?(feature) do
    case feature do
      :duration_selection -> true
      :inline_booking -> false
      :step_navigation -> true
      :glassmorphism -> true
      :calendar -> true
      _other -> false
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_meeting_action(assigns, action) do
    case action do
      :reschedule -> Reschedule.render(assigns)
      :cancel -> Cancel.render(assigns)
      :cancel_confirmed -> CancelConfirmed.render(assigns)
      _other -> raise "Unsupported meeting action: #{action}"
    end
  end
end

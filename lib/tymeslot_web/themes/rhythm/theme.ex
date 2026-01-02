defmodule TymeslotWeb.Themes.Rhythm.Theme do
  @moduledoc """
  Rhythm theme implementation with video background and 4-slide compact flow.
  """

  @behaviour TymeslotWeb.Themes.Core.Behaviour

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  @impl true
  def states do
    %{
      overview: %{step: 1, next: :schedule, prev: nil},
      schedule: %{step: 2, next: :booking, prev: :overview},
      booking: %{step: 3, next: :confirmation, prev: :schedule},
      confirmation: %{step: 4, prev: :booking}
    }
  end

  @impl true
  def css_file, do: "/assets/scheduling-theme-rhythm.css"

  @impl true
  def components do
    %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
  end

  @impl true
  def live_view_module do
    TymeslotWeb.Themes.Rhythm.Scheduling.Live
  end

  @impl true
  def theme_config do
    %{
      name: "Rhythm",
      description: "Video background with 4-slide flow",
      preview_image: "/images/themes/rhythm-preview.png",
      flow_steps: 4,
      design_system: :video_background,
      supports_duration_selection: true,
      supports_inline_booking: false
    }
  end

  @impl true
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

  @impl true
  def initial_state_for_action(live_action) do
    case live_action do
      :index -> :overview
      :overview -> :overview
      :schedule -> :schedule
      :book -> :booking
      :thank_you -> :confirmation
      :confirmation -> :confirmation
      _ -> :overview
    end
  end

  @impl true
  def supports_feature?(feature) do
    case feature do
      :duration_selection -> true
      :inline_booking -> false
      :step_navigation -> true
      :slide_navigation -> true
      :video_background -> true
      :compact_design -> true
      _ -> false
    end
  end
end

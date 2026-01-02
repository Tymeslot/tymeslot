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

  @impl true
  def states do
    %{
      overview: %{step: 1, next: :schedule, prev: nil},
      schedule: %{step: 2, next: :booking, prev: :overview},
      booking: %{step: 3, next: :confirmation, prev: :schedule},
      confirmation: %{step: 4, prev: nil}
    }
  end

  @impl true
  def css_file, do: "/assets/scheduling-theme-quill.css"

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
    TymeslotWeb.Themes.Quill.Scheduling.Live
  end

  @impl true
  def theme_config do
    %{
      name: "Quill",
      description: "Glass morphism design with elegant transparency effects",
      preview_image: "/images/themes/quill-preview.png",
      flow_steps: 4,
      design_system: :glassmorphism,
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
      :schedule -> :schedule
      :book -> :booking
      :thank_you -> :confirmation
      _ -> :overview
    end
  end

  @impl true
  def supports_feature?(feature) do
    case feature do
      :duration_selection -> true
      :inline_booking -> false
      :step_navigation -> true
      :glassmorphism -> true
      :calendar_grid -> true
      _ -> false
    end
  end
end

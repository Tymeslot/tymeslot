defmodule TymeslotWeb.Dashboard.ComponentDispatch do
  @moduledoc """
  Action-to-component dispatch for `DashboardLive`.

  Maps each `live_action` to its LiveComponent module, computes any prop
  overrides the component needs, evaluates feature-gates, and renders the
  placeholder shown when a feature is gated off. Extension components
  registered via `:dashboard_action_components` are resolved here too.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Naming
  alias Tymeslot.Agenda.Day
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.AutomationSettingsComponent
  alias TymeslotWeb.Dashboard.BookingsManagementComponent
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.DashboardOverviewComponent
  alias TymeslotWeb.Dashboard.IntegrationsHubComponent
  alias TymeslotWeb.Dashboard.Locations.LocationsComponent
  alias TymeslotWeb.Dashboard.PaymentsSettingsComponent
  alias TymeslotWeb.Dashboard.Polls.PollsComponent
  alias TymeslotWeb.Dashboard.ProfileSettingsComponent
  alias TymeslotWeb.Dashboard.ScheduleSettingsComponent
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent
  alias TymeslotWeb.Live.Dashboard.EmbedSettingsComponent

  @doc """
  Returns the stable string id used for the LiveComponent rendered for the
  given action. `send_update/2` callers must use this same id.
  """
  @spec component_id(atom()) :: String.t()
  def component_id(action), do: to_string(action)

  @doc """
  Resolves the LiveComponent module for the given action. Extension actions
  fall through to the registered `:dashboard_action_components` map, and an
  unknown action defaults to `DashboardOverviewComponent`.

  `opts` carries per-user choices that change which component a section
  renders: `calendar_redesign: true` renders the redesigned calendar.
  """
  @spec component_for_action(atom(), map() | nil, keyword()) :: module()
  def component_for_action(action, components, opts \\ [])
  def component_for_action(:overview, _components, _opts), do: DashboardOverviewComponent
  def component_for_action(:settings, _components, _opts), do: ProfileSettingsComponent
  def component_for_action(:availability, _components, _opts), do: ScheduleSettingsComponent
  def component_for_action(:meeting_settings, _components, _opts), do: ServiceSettingsComponent
  def component_for_action(:locations, _components, _opts), do: LocationsComponent

  def component_for_action(:calendar, _components, opts),
    do: calendar_component(Keyword.get(opts, :calendar_redesign, false))

  def component_for_action(:calendar_integration, _components, _opts),
    do: CalendarSettingsComponent

  def component_for_action(:video_integration, _components, _opts), do: VideoSettingsComponent
  def component_for_action(:integrations, _components, _opts), do: IntegrationsHubComponent
  def component_for_action(:automation, _components, _opts), do: AutomationSettingsComponent
  def component_for_action(:theme, _components, _opts), do: ThemeSettingsComponent
  def component_for_action(:theme_customization, _components, _opts), do: ThemeSettingsComponent
  def component_for_action(:meetings, _components, _opts), do: BookingsManagementComponent
  def component_for_action(:polls, _components, _opts), do: PollsComponent
  def component_for_action(:embed, _components, _opts), do: EmbedSettingsComponent
  def component_for_action(:payments, _components, _opts), do: PaymentsSettingsComponent

  def component_for_action(action, components, _opts) do
    Map.get(components || %{}, action, DashboardOverviewComponent)
  end

  @doc """
  The component the calendar section renders: the redesigned surface when the
  organiser's switch is on, the old grid otherwise. Parent-to-component
  updates for the calendar go to this module.
  """
  @spec calendar_component(boolean()) :: module()
  def calendar_component(true), do: CalendarSurface
  def calendar_component(_redesign?), do: CalendarGridComponent

  @doc """
  Returns a map of assign overrides for the given action. Only actions that
  need to transform assigns before passing them to the component are listed
  here; all other actions receive the socket assigns directly.
  """
  @spec props_for_action(map()) :: map()
  def props_for_action(%{live_action: :overview} = assigns) do
    %{shared_data: %{agenda: assigns[:agenda] || %Day{}}}
  end

  # The settings form suggests the browser's zone to a host who has none.
  def props_for_action(%{live_action: :settings} = assigns) do
    %{profile: Profiles.prefill_timezone(assigns.profile, assigns[:detected_timezone])}
  end

  # The availability page shows the hours and time off on the clock the
  # booking engine reads them on (`Profiles.timezone/1`), never the browser's.
  def props_for_action(%{live_action: :availability, profile: %{} = profile}) do
    %{profile: %{profile | timezone: Profiles.timezone(profile)}}
  end

  def props_for_action(%{live_action: :availability} = assigns),
    do: %{profile: assigns.profile}

  def props_for_action(_assigns), do: %{}

  @doc """
  Evaluates the feature gate for the given action. Returns `true` if the
  action is not gated or if the gating assign is truthy.
  """
  @spec should_render_feature?(atom(), map()) :: boolean()
  def should_render_feature?(action, assigns) do
    gates = assigns[:dashboard_feature_gates] || %{}

    case Map.get(gates, action) do
      nil -> true
      assign_key -> Map.get(assigns, assign_key, true)
    end
  end

  attr :section, :atom, required: true
  attr :current_user, :any, required: true
  attr :feature_placeholder_components, :map, required: true

  attr :variant, :atom,
    default: :page,
    values: [:page, :banner],
    doc:
      "`:page` when the placeholder stands in for the whole section, `:banner` when it sits above the section's own page"

  @doc """
  Renders the placeholder shown when a feature is gated off. Delegates to
  a registered placeholder component when one is configured, otherwise
  falls back to a generic message.

  The configured component receives `variant`: `:page` when it replaces the
  section, `:banner` when the section still renders below it under its own
  page heading, so the component should leave its page shell out.
  """
  @spec feature_placeholder(map()) :: Phoenix.LiveView.Rendered.t()
  def feature_placeholder(assigns) do
    assigns =
      assigns
      |> assign(:placeholder_component, assigns.feature_placeholder_components[assigns.section])
      |> assign(:feature_name, Naming.humanize(assigns.section))

    ~H"""
    <%= if @placeholder_component do %>
      <.live_component
        module={@placeholder_component}
        id={"#{@section}_placeholder"}
        current_user={@current_user}
        feature={@section}
        variant={@variant}
      />
    <% else %>
      <%!-- Core fallback: just show a simple message --%>
      <div class="p-8 text-center text-tymeslot-500">
        <p>
          {dgettext(
            "dashboard_common",
            "This feature (%{feature_name}) is not available on your current plan.",
            feature_name: @feature_name
          )}
        </p>
      </div>
    <% end %>
    """
  end
end

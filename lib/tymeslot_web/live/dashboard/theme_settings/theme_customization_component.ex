defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent do
  @moduledoc """
  Theme customization component for advanced theme settings.
  Allows users to customize colors and backgrounds for their booking page.

  Assigns contract
  - Required (passed in):
    - profile: Tymeslot.Profiles.ProfileSchema.t()
    - theme_id: String.t()
  - Provided/managed by this component (do not pass these in):
    - customization: map with current customization state (see customization_t())
    - option_groups: the theme spec's option groups, one panel each (`ThemeCustomizations.option_groups/1`)
    - panels: the panel module for each group, keyed by the group's key (`Panels.for_group/2`)
    - panel_ui: each group's panel UI state, keyed by the group's key (`Panel.ui/3`, `Panel.handle_ui/5`)
    - uploads: map() – upload entries keyed by asset field (`AssetUploads`), present only when the spec declares asset fields
    - parent_component: term() – reference to parent component for close actions (optional)
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Dashboard.ThemeSettings.AssetUploads
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels
  alias TymeslotWeb.Live.Shared.Flash

  @typedoc "Customization applied to the theme"
  @type customization_t :: Tymeslot.ThemeCustomizations.ThemeCustomizationSchema.t()

  @typedoc "Assigns contract for this component"
  @type assigns_t :: %{
          required(:profile) => Tymeslot.Profiles.ProfileSchema.t(),
          required(:theme_id) => String.t(),
          required(:customization) => customization_t(),
          required(:option_groups) => [map()],
          required(:panels) => %{atom() => module()},
          required(:panel_ui) => %{atom() => map()},
          optional(:uploads) => map() | nil,
          optional(:parent_component) => term()
        }

  @impl Phoenix.LiveComponent
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket), do: {:ok, socket}

  @impl Phoenix.LiveComponent
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{consume_upload: field}, socket),
    do: {:ok, consume_upload_and_notify(socket, field)}

  def update(assigns, socket) do
    theme_id = assigns[:theme_id] || Catalog.default_id()

    %{customization: customization} =
      ThemeCustomizations.initialize_customization(assigns.profile.id, theme_id)

    option_groups = ThemeCustomizations.option_groups(theme_id)
    panels = Map.new(option_groups, &{&1.key, Panels.for_group(theme_id, &1)})

    {:ok,
     socket
     |> assign(
       id: assigns.id,
       profile: assigns.profile,
       parent_component: assigns[:parent_component],
       theme_id: theme_id,
       customization: customization,
       option_groups: option_groups,
       panels: panels
     )
     |> AssetUploads.configure(__MODULE__, ThemeCustomizations.asset_fields(theme_id))
     |> assign_new(:panel_ui, fn ->
       Map.new(option_groups, fn group ->
         {group.key, panels[group.key].ui(group, customization, %{})}
       end)
     end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8" phx-hook="AutoUpload" id="theme-customization-uploads">
      <Components.toolbar
        profile={@profile}
        theme_id={@theme_id}
        parent_component={@parent_component}
      />

      <Components.option_panel
        :for={group <- @option_groups}
        panel={@panels[group.key]}
        group={group}
        customization={@customization}
        uploads={assigns[:uploads]}
        myself={@myself}
        {@panel_ui[group.key]}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event(
        "theme:set_option",
        %{"option" => option, "field" => field, "choice" => choice},
        socket
      )
      when is_binary(option) and is_binary(field) and is_binary(choice) do
    with_group(socket, option, &set_option(socket, &1, field, choice))
  end

  def handle_event("theme:set_option", _params, socket), do: {:noreply, socket}

  # Any other `theme:` event is a UI event of the panel whose group it names.
  def handle_event("theme:" <> _action = event, %{"option" => option} = params, socket)
      when is_binary(option) do
    with_group(socket, option, &panel_event(socket, &1, event, params))
  end

  def handle_event("theme:" <> _action, _params, socket), do: {:noreply, socket}

  # Every upload form sends this on change and on submit; its hidden
  # `asset_field` input names the field. A name the theme does not declare is
  # ignored rather than turned into an atom.
  def handle_event("upload_asset", params, socket) do
    case upload_field(socket.assigns.theme_id, params) do
      nil -> {:noreply, socket}
      field -> {:noreply, consume_upload_and_notify(socket, field)}
    end
  end

  # Private functions

  defp with_group(socket, option, fun) do
    case Enum.find(socket.assigns.option_groups, &(Atom.to_string(&1.key) == option)) do
      nil -> {:noreply, socket}
      group -> fun.(group)
    end
  end

  defp panel_event(socket, group, event, params) do
    %{panels: panels, panel_ui: panel_ui, customization: customization} = socket.assigns

    case panels[group.key].handle_ui(event, params, group, panel_ui[group.key], customization) do
      {:ui, ui} -> {:noreply, put_panel_ui(socket, group, ui)}
      {:set, field, value} -> set_option(socket, group, field, value)
      :ignore -> {:noreply, socket}
    end
  end

  defp set_option(socket, group, field, value) do
    panel = socket.assigns.panels[group.key]
    {event, action, metadata} = panel.telemetry(group, field, value)

    with_rate_limit(socket, action, fn ->
      case ThemeCustomizations.apply_option(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             group.key,
             %{"field" => field, "value" => value}
           ) do
        {:ok, updated} ->
          emit_telemetry(event, socket, metadata)
          ui = panel.ui(group, updated, socket.assigns.panel_ui[group.key])

          {:noreply,
           socket
           |> assign(:customization, updated)
           |> put_panel_ui(group, ui)}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  defp put_panel_ui(socket, group, ui),
    do: update(socket, :panel_ui, &Map.put(&1, group.key, ui))

  # `AutoUpload` (mounted at the root of this component's markup, see
  # `render/1`) only clears the file picker once it receives "upload-complete",
  # so re-selecting the same background file after a successful upload needs
  # this pushed explicitly. `AssetUploads.consume/2` doesn't report
  # success directly, so success is inferred from the stored path changing;
  # a no-op (not ready yet, rate-limited, or a validation error) leaves the
  # path untouched and pushes nothing.
  defp consume_upload_and_notify(socket, field) do
    path_before = stored_path(socket.assigns.customization, field)
    socket = AssetUploads.consume(socket, field)
    path_after = stored_path(socket.assigns.customization, field)

    if path_after != path_before do
      push_event(socket, "upload-complete", %{})
    else
      socket
    end
  end

  defp stored_path(customization, field), do: customization.settings[Atom.to_string(field)]

  defp upload_field(theme_id, %{"asset_field" => name}) when is_binary(name) do
    theme_id
    |> ThemeCustomizations.asset_fields()
    |> Keyword.keys()
    |> Enum.find(&(Atom.to_string(&1) == name))
  end

  defp upload_field(_theme_id, _params), do: nil

  # Rate limiting helper that validates user_id and checks rate limit before executing operation
  @spec with_rate_limit(Socket.t(), String.t(), (-> {:noreply, Socket.t()})) ::
          {:noreply, Socket.t()}
  defp with_rate_limit(socket, action, operation) do
    user_id = socket.assigns.profile.user_id
    profile_id = socket.assigns.profile.id

    # Validate user_id before proceeding
    if is_nil(user_id) or not is_integer(user_id) or user_id <= 0 do
      Logger.error("Invalid user_id in theme customization",
        user_id: LogFormat.reason(user_id),
        profile_id: profile_id
      )

      Flash.error(
        dgettext(
          "dashboard_appearance",
          "An error occurred. Please refresh the page and try again."
        )
      )

      {:noreply, socket}
    else
      case RateLimiter.check_theme_customization_rate_limit(user_id) do
        :ok ->
          operation.()

        {:error, :rate_limited, message} ->
          emit_telemetry(:rate_limited, socket, %{action: action})
          Flash.error(message)
          {:noreply, socket}

        {:error, :invalid_user_id} ->
          Logger.error("Rate limiter rejected invalid user_id",
            user_id: LogFormat.reason(user_id),
            profile_id: profile_id
          )

          Flash.error(
            dgettext(
              "dashboard_appearance",
              "An error occurred. Please refresh the page and try again."
            )
          )

          {:noreply, socket}
      end
    end
  end

  # Emit telemetry events for monitoring and metrics
  # SECURITY: Telemetry handlers must be properly secured as these events include user_id and profile_id
  @spec emit_telemetry(atom(), Socket.t(), map()) :: :ok
  defp emit_telemetry(event_name, socket, metadata) do
    :telemetry.execute(
      [:tymeslot, :theme_customization, event_name],
      %{count: 1},
      Map.merge(
        %{
          user_id: socket.assigns.profile.user_id,
          profile_id: socket.assigns.profile.id,
          theme_id: socket.assigns.theme_id
        },
        metadata
      )
    )
  end
end

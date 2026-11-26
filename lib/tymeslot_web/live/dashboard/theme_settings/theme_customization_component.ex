defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent do
  @moduledoc """
  Theme customization component for advanced theme settings.
  Allows users to customize colors and backgrounds for their booking page.

  Assigns contract
  - Required (passed in):
    - profile: Tymeslot.Profiles.ProfileSchema.t() – may be the owner's profile as one of its booking pages presents it; colours are then read and written for that page (ThemeCustomizations.scope_for/1)
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

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Dashboard.ThemeSettings.AssetUploads
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.RateLimit

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
    do: {:ok, AssetUploads.consume(socket, field)}

  def update(assigns, socket) do
    theme_id = assigns[:theme_id] || Catalog.default_id()

    %{customization: customization} =
      ThemeCustomizations.initialize_customization(
        ThemeCustomizations.scope_for(assigns.profile),
        theme_id
      )

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
    <div class="space-y-8" id="theme-customization-uploads">
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

  # Every upload form sends this on change, which LiveView needs to validate
  # the selection. Saving waits for the upload's progress callback
  # (`AssetUploads`), so there is nothing to do here.
  def handle_event("upload_asset", _params, socket), do: {:noreply, socket}

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

    with_customization_limit(socket, action, fn ->
      case ThemeCustomizations.apply_option(
             ThemeCustomizations.scope_for(socket.assigns.profile),
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

  # Every theme edit shares one limit; a refusal is also counted per action.
  @spec with_customization_limit(Socket.t(), String.t(), (-> {:noreply, Socket.t()})) ::
          {:noreply, Socket.t()}
  defp with_customization_limit(socket, action, operation) do
    check = RateLimiter.check(:theme_customization, socket.assigns.profile.user_id)

    if match?({:error, :rate_limited, _message}, check),
      do: emit_telemetry(:rate_limited, socket, %{action: action})

    RateLimit.with_rate_limit(check, socket, operation)
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

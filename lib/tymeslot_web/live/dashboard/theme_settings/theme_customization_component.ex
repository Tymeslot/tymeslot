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
    - presets: preset collections for color schemes and backgrounds (see presets_t())
    - browsing_type: String.t() – which background category is currently browsed ("gradient" | "color" | "image" | "video")
    - uploads: map() | nil – upload entries (managed by this component)
    - parent_component: term() – reference to parent component for close actions (optional)
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Dashboard.ThemeSettings.BackgroundUploads
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components
  alias TymeslotWeb.Live.Shared.Flash

  @typedoc "Preset collections used by the component"
  @type presets_t :: %{
          required(:color_schemes) => %{optional(String.t()) => map()},
          required(:gradients) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:value) => String.t()
            }
          },
          required(:images) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              optional(:description) => String.t()
            }
          },
          required(:videos) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              required(:thumbnail) => String.t(),
              optional(:description) => String.t()
            }
          }
        }

  @typedoc "Customization map applied to the theme"
  @type customization_t :: %{
          required(:background_type) => String.t(),
          optional(:background_value) => String.t() | nil,
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil,
          optional(:color_scheme) => String.t()
        }

  @typedoc "Assigns contract for this component"
  @type assigns_t :: %{
          required(:profile) => Tymeslot.Profiles.ProfileSchema.t(),
          required(:theme_id) => String.t(),
          required(:customization) => customization_t(),
          required(:presets) => presets_t(),
          required(:browsing_type) => String.t(),
          optional(:uploads) => map() | nil,
          optional(:parent_component) => term()
        }

  @impl Phoenix.LiveComponent
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket) do
    socket = BackgroundUploads.configure(socket, __MODULE__)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{consume_upload: type}, socket) do
    # Handle async consumption from progress handlers
    {:noreply, socket} =
      case type do
        :image -> handle_event("save_background_image", %{}, socket)
        :video -> handle_event("save_background_video", %{}, socket)
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    theme_id = assigns[:theme_id] || "1"

    # Initialize customization data from the domain
    %{
      customization: customization,
      original: _original_state,
      presets: presets
    } = ThemeCustomizations.initialize_customization(assigns.profile.id, theme_id)

    # Narrow assigns surface: expose a small, consistent contract
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:profile, assigns.profile)
     |> assign(:parent_component, assigns[:parent_component])
     |> assign(:theme_id, theme_id)
     |> assign(:customization, customization)
     |> assign(:presets, presets)
     |> assign_new(:browsing_type, fn -> customization.background_type end)
     |> assign_new(:custom_picker_open, fn -> false end)
     |> assign_new(:palette_picker_open, fn ->
       not is_nil(customization.custom_palette_seed)
     end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8" phx-hook="AutoUpload" id="theme-customization-uploads">
      <.section_header level={3} title={dgettext("dashboard_appearance", "Theme Customization")} />
      <Components.toolbar
        profile={@profile}
        theme_id={@theme_id}
        parent_component={@parent_component}
      />

      <Components.color_scheme_section
        customization={@customization}
        presets={@presets}
        myself={@myself}
        palette_picker_open={@palette_picker_open}
      />

      <Components.background_section
        browsing_type={@browsing_type}
        customization={@customization}
        presets={@presets}
        uploads={@uploads}
        myself={@myself}
        custom_picker_open={@custom_picker_open}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("theme:select_color_scheme", %{"scheme" => scheme_id}, socket) do
    with_rate_limit(socket, "color_scheme", fn ->
      case ThemeCustomizations.apply_color_scheme_change(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             socket.assigns.customization,
             scheme_id
           ) do
        {:ok, updated_customization} ->
          emit_telemetry(:color_scheme_changed, socket, %{scheme_id: scheme_id})

          {:noreply,
           socket
           |> assign(:customization, updated_customization)
           |> assign(:palette_picker_open, not is_nil(updated_customization.custom_palette_seed))}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  def handle_event("theme:toggle_palette_picker", _params, socket) do
    if is_nil(socket.assigns.customization.custom_palette_seed) do
      with_rate_limit(socket, "color_scheme", fn ->
        case ThemeCustomizations.apply_color_scheme_change(
               socket.assigns.profile.id,
               socket.assigns.theme_id,
               socket.assigns.customization,
               "custom"
             ) do
          {:ok, updated} ->
            emit_telemetry(:palette_seed_set, socket, %{
              seed: updated.custom_palette_seed
            })

            {:noreply,
             socket
             |> assign(:customization, updated)
             |> assign(:palette_picker_open, true)}

          {:error, reason} ->
            Flash.error(reason)
            {:noreply, socket}
        end
      end)
    else
      {:noreply, update(socket, :palette_picker_open, &(!&1))}
    end
  end

  @valid_browsing_types ~w[gradient color image video]

  def handle_event("theme:set_browsing_type", %{"type" => type}, socket)
      when type in @valid_browsing_types do
    # Only update the browsing type - this is just UI navigation, not a selection
    {:noreply, assign(socket, :browsing_type, type)}
  end

  def handle_event("theme:set_browsing_type", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("theme:toggle_custom_picker", _params, socket) do
    {:noreply, update(socket, :custom_picker_open, &(!&1))}
  end

  def handle_event("theme:set_palette_seed", %{"value" => hex}, socket) do
    with_rate_limit(socket, "palette_seed", fn ->
      case ThemeCustomizations.apply_custom_palette_change(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             socket.assigns.customization,
             hex
           ) do
        {:ok, updated} ->
          emit_telemetry(:palette_seed_changed, socket, %{seed: hex})
          {:noreply, assign(socket, :customization, updated)}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  def handle_event("theme:set_custom_background", %{"value" => hex}, socket) do
    with_rate_limit(socket, "background", fn ->
      case ThemeCustomizations.apply_background_change(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             socket.assigns.customization,
             "color",
             hex
           ) do
        {:ok, updated} ->
          emit_telemetry(:background_changed, socket, %{type: "color", value: hex})

          {:noreply,
           socket
           |> assign(:customization, updated)
           |> assign(:browsing_type, "color")}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  def handle_event("theme:select_background", params, socket) do
    type = params["type"]
    value = params["id"] || params["value"]

    with_rate_limit(socket, "background", fn ->
      case ThemeCustomizations.apply_background_change(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             socket.assigns.customization,
             type,
             value
           ) do
        {:ok, updated_customization} ->
          emit_telemetry(:background_changed, socket, %{type: type, value: value})

          {:noreply,
           socket
           |> assign(:customization, updated_customization)
           |> assign(:browsing_type, type)}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  def handle_event("validate_image", _params, socket) do
    {:noreply, BackgroundUploads.consume(socket, :image)}
  end

  def handle_event("save_background_image", _params, socket) do
    {:noreply, BackgroundUploads.consume(socket, :image)}
  end

  def handle_event("validate_video", _params, socket) do
    {:noreply, BackgroundUploads.consume(socket, :video)}
  end

  def handle_event("save_background_video", _params, socket) do
    {:noreply, BackgroundUploads.consume(socket, :video)}
  end

  # Private functions

  # Rate limiting helper that validates user_id and checks rate limit before executing operation
  @spec with_rate_limit(Socket.t(), String.t(), (-> {:noreply, Socket.t()})) ::
          {:noreply, Socket.t()}
  defp with_rate_limit(socket, action, operation) do
    user_id = socket.assigns.profile.user_id
    profile_id = socket.assigns.profile.id

    # Validate user_id before proceeding
    if is_nil(user_id) or not is_integer(user_id) or user_id <= 0 do
      Logger.error("Invalid user_id in theme customization",
        user_id: inspect(user_id),
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
            user_id: inspect(user_id),
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

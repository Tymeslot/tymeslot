defmodule TymeslotWeb.Themes.Core.MountHelpers do
  @moduledoc "Socket initialisation helpers for the booking flow dispatcher."

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Themes.Registry
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Core.{Context, EventBus, MeetingManagement}
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: ThemeCustomizationHelpers

  @doc """
  Mounts the socket when an organizer profile is present.

  Delegates to either `mount_meeting_management/5` or `mount_scheduling_flow/4` depending on
  the live action and params. Accepts `delegate_fn` — a `(theme_id, function, args -> result)`
  function — for delegating scheduling-flow mounts to the theme module.
  """
  @spec mount_with_profile(map(), map(), map(), Phoenix.LiveView.Socket.t(), function()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount_with_profile(profile, params, session, socket, delegate_fn) do
    action = socket.assigns[:live_action]

    if action in [:reschedule, :cancel, :cancel_confirmed] && params["meeting_uid"] do
      mount_meeting_management(profile, params, socket, action)
    else
      mount_scheduling_flow(profile, params, session, socket, delegate_fn)
    end
  end

  @doc """
  Mounts the socket when no organizer profile is available.

  Accepts `delegate_fn` — a `(theme_id, function, args -> result)` function — for delegating
  mounts to the theme module.
  """
  @spec mount_without_profile(map(), map(), Phoenix.LiveView.Socket.t(), function()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount_without_profile(params, session, socket, delegate_fn) do
    if params["username"] && is_nil(socket.assigns[:organizer_profile]) do
      {:ok,
       socket
       |> LiveView.put_flash(:error, "Page not found. Redirected to homepage.")
       |> LiveView.redirect(to: ~p"/")}
    else
      case Context.from_params(params) do
        %Context{} = context ->
          EventBus.subscribe_to_theme(context.theme_id)

          socket = Context.assign_to_socket(socket, context)

          EventBus.emit_theme_mounted(context.theme_id, %{
            preview_mode: context.preview_mode
          })

          delegate_fn.(context.theme_id, :mount, [params, session, socket])

        nil ->
          {:ok, assign(socket, :error, "Failed to load theme context")}
      end
    end
  end

  @doc """
  Mounts a scheduling flow for a known organizer profile.

  Accepts `delegate_fn` — a `(theme_id, function, args -> result)` function — for delegating
  to the theme module.
  """
  @spec mount_scheduling_flow(map(), map(), map(), Phoenix.LiveView.Socket.t(), function()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount_scheduling_flow(profile, params, session, socket, delegate_fn) do
    case LinkAccessPolicy.check_public_readiness(profile) do
      {:ok, :ready} ->
        case prepare_theme_context(profile, params, socket) do
          {:ok, context, socket} ->
            EventBus.emit_theme_mounted(context.theme_id, %{
              user_id: profile.user_id,
              preview_mode: context.preview_mode
            })

            delegate_fn.(context.theme_id, :mount, [params, session, socket])

          {:error, error_socket} ->
            {:ok, error_socket}
        end

      {:error, reason} ->
        case prepare_theme_context(profile, params, socket) do
          {:ok, _context, socket} ->
            {:ok,
             socket
             |> LiveView.clear_flash()
             |> LiveView.put_flash(:error, LinkAccessPolicy.reason_to_message(reason))
             |> assign(:scheduling_error_reason, reason)
             |> assign(
               :scheduling_error_message,
               LinkAccessPolicy.reason_to_message(reason)
             )}

          {:error, error_socket} ->
            {:ok, error_socket}
        end
    end
  end

  @doc "Loads a meeting and prepares the socket for the cancel/reschedule/cancel_confirmed flow."
  @spec mount_meeting_management(map(), map(), Phoenix.LiveView.Socket.t(), atom()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount_meeting_management(profile, params, socket, action) do
    theme_id = profile.booking_theme || socket.assigns[:theme_id] || Registry.default_theme_id()
    meeting_uid = params["meeting_uid"]

    case MeetingManagement.validate_and_load_meeting(meeting_uid, action, profile.user_id) do
      {:ok, meeting} ->
        socket =
          setup_meeting_management_socket(
            socket,
            profile,
            meeting,
            meeting_uid,
            theme_id,
            action,
            params
          )

        {:ok, socket}

      {:error, reason} ->
        {:ok,
         socket
         |> LiveView.put_flash(:error, reason)
         |> LiveView.redirect(to: ~p"/")}
    end
  end

  @doc "Assigns the validated user timezone from params or socket assigns."
  @spec assign_user_timezone(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_user_timezone(socket, params) do
    timezone =
      params["timezone"] || socket.assigns[:user_timezone] ||
        Profiles.get_default_timezone()

    normalized_timezone = Timezones.normalize(timezone)

    validated_timezone =
      if Timezones.valid?(normalized_timezone) do
        normalized_timezone
      else
        Profiles.get_default_timezone()
      end

    assign(socket, :user_timezone, validated_timezone)
  end

  @doc "Builds the theme context from params and profile, assigns it to the socket."
  @spec prepare_theme_context(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Context.t(), Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def prepare_theme_context(profile, params, socket) do
    case Context.from_params(params, profile) do
      %Context{} = context ->
        EventBus.subscribe_to_theme(context.theme_id)

        socket =
          socket
          |> Context.assign_to_socket(context)
          |> ThemeCustomizationHelpers.assign_theme_customization(profile, context.theme_id)

        {:ok, context, socket}

      nil ->
        {:error, assign(socket, :error, "Failed to load theme context")}
    end
  end

  # Private

  defp setup_meeting_management_socket(
         socket,
         profile,
         meeting,
         meeting_uid,
         theme_id,
         action,
         params
       ) do
    socket =
      socket
      |> assign(:theme_id, theme_id)
      |> assign(:organizer_profile, profile)
      |> assign(:meeting, meeting)
      |> assign(:meeting_uid, meeting_uid)
      |> assign(:loading, false)
      |> assign(:has_theme, true)

    socket =
      case Context.from_params(params, profile) do
        %Context{} = context -> Context.assign_to_socket(socket, context)
        nil -> socket
      end

    socket = MeetingManagement.assign_action_specific_data(socket, action, meeting, params)
    ThemeCustomizationHelpers.assign_theme_customization(socket, profile, theme_id)
  end
end

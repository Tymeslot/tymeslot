defmodule TymeslotWeb.Live.Scheduling.OrganizerHelpers do
  @moduledoc """
  Per-request organizer setup helpers for the scheduling flow.

  Owns the slice of socket state that does not depend on calendar
  availability: username resolution, the booking form, and the client
  IP captured at mount.
  """

  alias Phoenix.Component
  alias Tymeslot.Demo
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.BookingConfig

  import Component, only: [assign: 3]

  @doc """
  Handles username resolution and organizer setup.
  """
  @spec handle_username_resolution(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def handle_username_resolution(socket, nil) do
    socket
    |> store_client_ip()
    |> assign(:username_context, nil)
  end

  def handle_username_resolution(socket, username) do
    # Store client IP during username resolution to ensure it's available later
    socket = store_client_ip(socket)

    case Demo.resolve_organizer_context(username) do
      {:error, :profile_not_found} ->
        # During mount, we can't use put_flash/redirect - let the mount handle this
        socket
        |> assign(:username_context, nil)
        |> assign(:organizer_profile, nil)
        |> assign(:organizer_user_id, nil)
        |> assign(:meeting_types, [])
        |> assign(:page_title, "User Not Found")

      {:ok, context} ->
        socket
        |> assign(:username_context, context.username)
        |> assign(:organizer_profile, context.profile)
        |> assign(:organizer_user_id, context.user_id)
        |> assign(:meeting_types, context.meeting_types)
        |> assign(:page_title, context.page_title)
    end
  end

  @doc "Initialises form, touched-field, validation-error, and saving assigns."
  @spec setup_form_state(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def setup_form_state(socket, form_data \\ %{}, opts \\ []) do
    as = Keyword.get(opts, :as)

    socket
    |> assign(:form, Component.to_form(form_data, as: as))
    |> assign(:touched_fields, MapSet.new())
    |> assign(:validation_errors, %{})
    |> assign(:saving, false)
  end

  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_form_errors(socket, error_map) when is_map(error_map) do
    assign(socket, :validation_errors, error_map)
  end

  @doc """
  Returns a CSS class if the field has errors.
  """
  @spec field_error_class(Phoenix.HTML.Form.t(), atom()) :: String.t()
  def field_error_class(form, field) do
    if Enum.any?(get_field_errors(form, field)), do: "error", else: ""
  end

  @doc """
  Gets error messages for a specific field from the form.
  """
  @spec get_field_errors(Phoenix.HTML.Form.t(), atom()) :: [String.t()]
  def get_field_errors(form, field) do
    case form[field] do
      %{errors: errors} when is_list(errors) ->
        Enum.map(errors, fn {msg, _opts} -> msg end)

      _other ->
        []
    end
  end

  @doc """
  Marks a form field as touched.
  """
  @spec mark_field_touched(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mark_field_touched(socket, field_name) do
    assign(socket, :touched_fields, MapSet.put(socket.assigns.touched_fields, field_name))
  end

  @doc """
  Gets client IP address for rate limiting.
  Delegates to the unified ClientIP module.
  """
  @spec get_client_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_client_ip(socket) do
    ClientIP.get(socket)
  end

  @doc """
  Stores client IP in socket assigns during mount.
  Should be called during mount to capture IP for later use.
  """
  @spec store_client_ip(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def store_client_ip(socket) do
    # Try mount-specific extraction first if not already in assigns
    ip =
      case socket.assigns[:client_ip] do
        ip when is_binary(ip) ->
          ip

        _other ->
          # get_from_mount/1 should only be called during mount.
          # We wrap it in try-rescue to prevent crashes if called during events.
          try do
            ClientIP.get_from_mount(socket)
          rescue
            _error -> "unknown"
          end
      end

    assign(socket, :client_ip, ip)
  end

  @doc """
  Validates if form is complete and valid.
  """
  @spec form_valid?(Phoenix.HTML.Form.t()) :: boolean()
  def form_valid?(%{source: source}) when is_map(source) do
    case InputProcessor.validate_form(source, BookingConfig.booking_field_spec()) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  end

  def form_valid?(_form), do: false
end

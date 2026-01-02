defmodule TymeslotWeb.Live.Shared.LiveHelpers do
  @moduledoc """
  Helper functions for LiveViews.
  These are functions that work with socket assigns, not components.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Ecto.Changeset
  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.Security
  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Helpers.ClientIP

  # ========== USER HELPERS ==========

  @doc """
  Assigns the current user to the socket based on session token.

  If a valid user_token exists in the session, fetches and assigns the user.
  Otherwise, assigns nil to current_user.
  """
  @spec assign_current_user(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_current_user(socket, session) do
    case session do
      %{"user_token" => user_token} when not is_nil(user_token) ->
        user = Authentication.get_user_by_session_token(user_token)
        assign(socket, :current_user, user)

      _ ->
        assign(socket, :current_user, nil)
    end
  end

  # ========== TIMEZONE HELPERS ==========

  @doc """
  Assigns user timezone to the socket, checking params, connection info, then defaulting.
  """
  @spec assign_user_timezone(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_user_timezone(socket, params) do
    timezone =
      params["timezone"] ||
        get_connect_params(socket)["timezone"] ||
        "Europe/Kyiv"

    # Normalize timezone to ensure consistency
    normalized_timezone = TimezoneUtils.normalize_timezone(timezone)
    assign(socket, :user_timezone, normalized_timezone)
  end

  @doc """
  Validates and updates timezone on the socket.
  """
  @spec update_timezone(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def update_timezone(socket, new_timezone) do
    case Security.validate_timezone(new_timezone) do
      {:ok, validated} ->
        # Normalize timezone to ensure consistency
        normalized_timezone = TimezoneUtils.normalize_timezone(validated)
        assign(socket, :user_timezone, normalized_timezone)

      {:error, _} ->
        socket
    end
  end

  # ========== CONNECTION HELPERS ==========

  @doc """
  Gets the client IP address from the socket connection.
  Delegates to the unified ClientIP module.
  """
  @spec get_client_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_client_ip(socket) do
    ClientIP.get(socket)
  end

  # ========== FORM HELPERS ==========

  @doc """
  Sets up initial form state on the socket.
  """
  @spec setup_form_state(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def setup_form_state(socket, initial_data \\ %{}) do
    socket
    |> assign(:form, to_form(initial_data))
    |> assign(:touched_fields, MapSet.new())
    |> assign(:validation_errors, [])
    |> assign(:submitting, false)
  end

  @doc """
  Marks a field as touched for validation display.
  """
  @spec mark_field_touched(Phoenix.LiveView.Socket.t(), String.t() | atom()) ::
          Phoenix.LiveView.Socket.t()
  def mark_field_touched(socket, field_name) when is_binary(field_name) do
    mark_field_touched(socket, String.to_existing_atom(field_name))
  end

  def mark_field_touched(socket, field_name) when is_atom(field_name) do
    touched = MapSet.put(socket.assigns.touched_fields, field_name)
    assign(socket, :touched_fields, touched)
  end

  @doc """
  Filters validation errors to only show for touched fields.
  """
  @spec filter_errors_for_touched_fields(list(), MapSet.t()) :: list()
  def filter_errors_for_touched_fields(errors, touched_fields) do
    Enum.filter(errors, fn {field, _message} ->
      MapSet.member?(touched_fields, field)
    end)
  end

  @doc """
  Updates form with validation errors.
  """
  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), list() | Changeset.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_form_errors(socket, errors) when is_list(errors) do
    # Filter errors for touched fields
    filtered_errors = filter_errors_for_touched_fields(errors, socket.assigns.touched_fields)
    assign(socket, :validation_errors, filtered_errors)
  end

  def assign_form_errors(socket, changeset) do
    errors =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    flat_errors =
      Enum.flat_map(errors, fn {field, messages} ->
        Enum.map(messages, fn msg -> {field, msg} end)
      end)

    assign_form_errors(socket, flat_errors)
  end

  # ========== NAVIGATION HELPERS ==========

  @doc """
  Redirects to thank you page with meeting details.
  """
  @spec redirect_to_thank_you(Phoenix.LiveView.Socket.t(), Ecto.Schema.t()) ::
          Phoenix.LiveView.Socket.t()
  def redirect_to_thank_you(socket, meeting) do
    params = %{
      name: meeting.attendee_name,
      date: Date.to_iso8601(DateTime.to_date(meeting.start_time)),
      time: format_time_for_display(meeting.start_time, socket.assigns.user_timezone),
      duration: to_string(meeting.duration),
      timezone: socket.assigns.user_timezone,
      email: meeting.attendee_email,
      meeting_uid: meeting.uid
    }

    query_string = URI.encode_query(params)

    path =
      if socket.assigns[:username_context] do
        "/#{socket.assigns.username_context}/schedule/thank-you"
      else
        "/"
      end

    push_navigate(socket, to: "#{path}?#{query_string}")
  end

  @doc """
  Common helper to handle form submission state.
  """
  @spec with_submission_state(Phoenix.LiveView.Socket.t(), function()) ::
          {:ok, Phoenix.LiveView.Socket.t(), any()} | {:error, Phoenix.LiveView.Socket.t(), any()}
  def with_submission_state(socket, fun) do
    socket = assign(socket, :submitting, true)

    case fun.() do
      {:ok, result} ->
        {:ok, assign(socket, :submitting, false), result}

      {:error, reason} ->
        {:error, assign(socket, :submitting, false), reason}
    end
  end

  # ========== UTILITY HELPERS ==========

  @doc """
  Shorthand for {:ok, socket} returns.
  """
  @spec ok(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def ok(socket), do: {:ok, socket}

  @doc """
  Shorthand for {:noreply, socket} returns.
  """
  @spec noreply(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def noreply(socket), do: {:noreply, socket}

  defp format_time_for_display(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%-I:%M %p")
      _ -> Calendar.strftime(datetime, "%-I:%M %p")
    end
  end
end

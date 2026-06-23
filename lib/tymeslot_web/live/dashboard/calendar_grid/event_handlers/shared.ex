defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared do
  @moduledoc "Shared helpers used across EventHandlers submodules."

  alias Tymeslot.Security.RateLimiter

  @spec parse_int(binary()) :: {:ok, integer()} | :error
  @spec parse_int(term()) :: :error
  def parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  def parse_int(_not_binary), do: :error

  # Constructs a UTC DateTime from a date and time in the user's display timezone.
  # The calendar grid renders events in the user's timezone, so drag/drop/create
  # coordinates are in that timezone and must be converted back to UTC for storage.
  # The timezone is validated at mount time (DataLoading.precompute_derived/1), so
  # it is safe to use the bang variant here.
  @spec to_utc(Date.t(), non_neg_integer(), non_neg_integer(), String.t()) :: DateTime.t()
  def to_utc(date, hour, minute, timezone) do
    local_dt = DateTime.new!(date, Time.new!(hour, minute, 0, {0, 6}), timezone)
    DateTime.shift_zone!(local_dt, "Etc/UTC")
  end

  @spec clamp_end_time(Date.t(), non_neg_integer(), non_neg_integer()) ::
          {Date.t(), non_neg_integer(), non_neg_integer()}
  def clamp_end_time(date, hour, minute) when hour >= 24 do
    {Date.add(date, 1), 0, minute}
  end

  def clamp_end_time(date, hour, minute), do: {date, hour, minute}

  @spec check_edit_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_edit_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_event_edit_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @spec check_move_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_move_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_event_move_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @spec valid_email?(binary()) :: boolean()
  @spec valid_email?(term()) :: false
  def valid_email?(email) when is_binary(email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end

  def valid_email?(_other), do: false

  # Allowed reminder lead times (minutes before the event start) offered as
  # presets in the editor. Values outside this set are rejected so the UI
  # cannot feed arbitrary integers into the provider write.
  @reminder_minutes_presets [5, 10, 30, 60, 1440]

  @doc """
  Returns the allowed reminder lead times in minutes, ordered ascending.
  """
  @spec reminder_minutes_presets() :: [pos_integer()]
  def reminder_minutes_presets, do: @reminder_minutes_presets

  @doc """
  Parses a reminder from `phx-value-method` / `phx-value-minutes` params into the
  canonical `%{method: :popup | :email, minutes_before: integer}` shape. Returns
  `:error` for an unknown method or a lead time outside the allowed presets.
  """
  @spec parse_reminder(map()) :: {:ok, %{method: atom(), minutes_before: pos_integer()}} | :error
  def parse_reminder(params) do
    with {:ok, method} <- parse_reminder_method(params["method"]),
         {:ok, minutes} <- parse_int(params["minutes"]),
         true <- minutes in @reminder_minutes_presets do
      {:ok, %{method: method, minutes_before: minutes}}
    else
      _invalid -> :error
    end
  end

  defp parse_reminder_method("popup"), do: {:ok, :popup}
  defp parse_reminder_method("email"), do: {:ok, :email}
  defp parse_reminder_method(_other), do: :error
end

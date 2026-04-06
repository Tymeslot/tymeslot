defmodule Tymeslot.Notifications.SchedulingRules do
  @moduledoc """
  Defines when notifications should be sent and their scheduling parameters.
  Pure functions that determine notification timing and delivery rules.
  """

  @typep email_timing :: %{
           required(:timing) => :immediate | {:before_meeting, pos_integer()},
           required(:priority) => non_neg_integer(),
           required(:uniqueness_window) => non_neg_integer(),
           required(:max_attempts) => pos_integer(),
           required(:backoff_strategy) => [pos_integer()]
         }

  @doc """
  Returns the timing configuration for confirmation emails.
  """
  @spec confirmation_email_timing() :: email_timing()
  def confirmation_email_timing do
    %{
      timing: :immediate,
      priority: 0,
      # 5 minutes
      uniqueness_window: 5 * 60,
      max_attempts: 5,
      backoff_strategy: exponential_backoff()
    }
  end

  @doc """
  Returns the timing configuration for reminder emails.
  """
  @spec reminder_email_timing() :: email_timing()
  def reminder_email_timing do
    %{
      timing: {:before_meeting, reminder_minutes()},
      priority: 2,
      # 1 hour
      uniqueness_window: 60 * 60,
      max_attempts: 5,
      backoff_strategy: exponential_backoff()
    }
  end

  @doc """
  Returns the timing configuration for cancellation emails.
  """
  @spec cancellation_email_timing() :: email_timing()
  def cancellation_email_timing do
    %{
      timing: :immediate,
      priority: 1,
      # No uniqueness window for cancellations
      uniqueness_window: 0,
      max_attempts: 3,
      backoff_strategy: exponential_backoff()
    }
  end

  @doc """
  Returns the timing configuration for reschedule emails.
  """
  @spec reschedule_email_timing() :: email_timing()
  def reschedule_email_timing do
    %{
      timing: :immediate,
      priority: 1,
      # 5 minutes
      uniqueness_window: 5 * 60,
      max_attempts: 5,
      backoff_strategy: exponential_backoff()
    }
  end

  @doc """
  Returns the timing configuration for video room notification emails.
  """
  @spec video_room_email_timing() :: email_timing()
  def video_room_email_timing do
    %{
      timing: :immediate,
      priority: 1,
      # 5 minutes
      uniqueness_window: 5 * 60,
      max_attempts: 3,
      backoff_strategy: exponential_backoff()
    }
  end

  @doc """
  Calculates the scheduled time for a reminder email.
  """
  @spec calculate_reminder_time(DateTime.t(), pos_integer(), String.t()) :: DateTime.t()
  def calculate_reminder_time(meeting_start_time, value, unit) do
    seconds = reminder_interval_seconds(value, unit)
    DateTime.add(meeting_start_time, -seconds, :second)
  end

  @doc """
  Determines if a reminder should be scheduled based on meeting timing.
  """
  @spec should_schedule_reminder?(DateTime.t(), pos_integer(), String.t()) :: boolean()
  def should_schedule_reminder?(meeting_start_time, value, unit) do
    reminder_time = calculate_reminder_time(meeting_start_time, value, unit)
    DateTime.compare(reminder_time, DateTime.utc_now()) == :gt
  end

  @doc """
  Returns the retry policy for notifications.
  """
  @spec retry_policy() :: %{
          optional(:initial_delay) => pos_integer(),
          optional(:max_retries) => non_neg_integer(),
          optional(:backoff_factor) => number(),
          optional(:max_attempts) => non_neg_integer(),
          optional(:backoff) => [pos_integer()],
          optional(:rate_limit_snooze) => pos_integer()
        }
  def retry_policy do
    %{
      max_attempts: 5,
      backoff: exponential_backoff(),
      # 5 minutes
      rate_limit_snooze: 300
    }
  end

  @doc """
  Returns priority levels for different notification types.
  """
  @spec priority_levels() :: %{
          required(:confirmation) => non_neg_integer(),
          required(:cancellation) => non_neg_integer(),
          required(:reschedule) => non_neg_integer(),
          required(:video_room) => non_neg_integer(),
          required(:reminder) => non_neg_integer()
        }
  def priority_levels do
    %{
      # Highest priority
      confirmation: 0,
      # High priority
      cancellation: 1,
      # High priority
      reschedule: 1,
      # High priority
      video_room: 1,
      # Medium priority
      reminder: 2
    }
  end

  # Private functions

  defp reminder_minutes do
    Keyword.get(Application.get_env(:tymeslot, :notifications, []), :reminder_minutes, 30)
  end

  defp reminder_interval_seconds(value, unit) when is_integer(value) and value > 0 do
    multiplier =
      case unit do
        "minutes" -> 60
        "hours" -> 3600
        "days" -> 86_400
        _other -> 60
      end

    value * multiplier
  end

  defp reminder_interval_seconds(_value, _unit), do: reminder_minutes() * 60

  defp exponential_backoff do
    # seconds
    [1, 2, 4, 8, 16]
  end
end

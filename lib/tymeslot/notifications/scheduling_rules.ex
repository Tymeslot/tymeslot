defmodule Tymeslot.Notifications.SchedulingRules do
  @moduledoc """
  Defines when notifications should be sent and their scheduling parameters.
  Pure functions that determine notification timing and delivery rules.
  """

  @doc """
  Returns the timing configuration for confirmation emails.
  """
  @spec confirmation_email_timing() :: map()
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
  @spec reminder_email_timing() :: map()
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
  @spec cancellation_email_timing() :: map()
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
  @spec reschedule_email_timing() :: map()
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
  @spec video_room_email_timing() :: map()
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
  @spec calculate_reminder_time(DateTime.t()) :: DateTime.t()
  def calculate_reminder_time(meeting_start_time) do
    DateTime.add(meeting_start_time, -reminder_minutes() * 60, :second)
  end

  @doc """
  Determines if a reminder should be scheduled based on meeting timing.
  """
  @spec should_schedule_reminder?(DateTime.t()) :: boolean()
  def should_schedule_reminder?(meeting_start_time) do
    reminder_time = calculate_reminder_time(meeting_start_time)
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
  @spec priority_levels() :: map()
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

  defp exponential_backoff do
    # seconds
    [1, 2, 4, 8, 16]
  end
end

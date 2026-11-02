defmodule Tymeslot.Emails.EmailScheduler.OnboardingScheduler do
  @moduledoc "Schedules the emails a new host asks for while setting up, via Oban."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  # A second click inside this window coalesces with the first.
  @booking_link_window_seconds 600

  @doc """
  Schedules the host's own booking link. One job per user per ten minutes,
  whatever state the first one is in, so a double click never sends it twice.
  """
  @spec schedule_booking_link(term()) :: {:ok, :scheduled | :duplicate} | {:error, term()}
  def schedule_booking_link(user_id) do
    %{"action" => "send_booking_link_email", "user_id" => user_id}
    |> EmailWorker.new(
      queue: :emails,
      unique: [
        period: @booking_link_window_seconds,
        fields: [:args, :queue],
        keys: [:action, :user_id],
        states: [:scheduled, :available, :executing, :retryable, :completed]
      ]
    )
    |> Helpers.insert(user_id: user_id)
  end
end

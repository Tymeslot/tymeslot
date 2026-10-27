defmodule Tymeslot.Auth.AccountDeletion.ExternalCleanup do
  @moduledoc """
  Best-effort cleanup of what an account being deleted left with third
  parties. Runs before the row delete, because the cascade removes the
  credentials each step needs:

    * calendars: stop Google push channels, delete Microsoft Graph
      subscriptions, revoke Google grants;
    * video: revoke Google Meet and Zoom grants;
    * Slack: revoke bot tokens;
    * payments: expire pending Stripe Checkout sessions and close the
      Connect account record (`MeetingPayments.disconnect/1`, which sends no
      email or webhook).

  Calendar events and video rooms of future meetings are deliberately left
  alone: the meeting may still take place between host and guest. Each step
  is isolated, so one provider being down, or one step raising, stops
  neither the other steps nor the deletion.
  """

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Infrastructure.BestEffort
  alias Tymeslot.Integrations.Calendar.AccountCleanup, as: CalendarCleanup
  alias Tymeslot.Integrations.Video.AccountCleanup, as: VideoCleanup
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Slack

  @spec run(UserSchema.t()) :: :ok
  def run(%UserSchema{id: user_id}) do
    steps = [
      calendars: fn -> CalendarCleanup.run(user_id) end,
      video: fn -> VideoCleanup.run(user_id) end,
      slack: fn -> Slack.revoke_tokens_for_user(user_id) end,
      payments: fn -> MeetingPayments.disconnect(%{id: user_id}) end
    ]

    Enum.each(steps, fn {step, fun} -> run_step(step, user_id, fun) end)
  end

  # Public only so the `{:error, _}` branch can be tested: no real step returns
  # one except a failed payments transaction, which cannot be provoked cleanly.
  @doc false
  @spec run_step(atom(), integer(), (-> term())) :: :ok
  def run_step(step, user_id, fun) do
    BestEffort.run(step, fun, "Account deletion: cleanup step failed; the deletion goes ahead",
      user_id: user_id
    )
  end
end

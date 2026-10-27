defmodule Tymeslot.Notifications.ResumePlanDisabledIntegrationsMigrationTest do
  @moduledoc """
  Verifies `20261010104132_resume_integrations_switched_off_for_plan`
  switches back on only the Slack and Telegram integrations whose sole
  disable reason is the old plan sentence, and leaves every other state
  alone. See `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :notifications
  @moduletag :migrations

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_010_104_132
  @plan_reason "Plan no longer permits automations"

  for {factory, schema} <- [
        {:slack_integration, SlackIntegrationSchema},
        {:telegram_integration, TelegramIntegrationSchema}
      ] do
    test "#{inspect(schema)}: only rows switched off for the plan come back on" do
      user = insert(:user)
      at = DateTime.add(DateTime.utc_now(), -86_400, :second)
      off = fn attrs -> insert(unquote(factory), [user: user, is_active: false] ++ attrs) end

      plan = off.(disabled_at: at, disabled_reason: @plan_reason, failure_count: 3)
      other = off.(disabled_at: at, disabled_reason: "too_many_failures", failure_count: 10)
      lookalike = off.(disabled_at: at, disabled_reason: @plan_reason <> ".")
      paused = off.([])
      active = insert(unquote(factory), user: user)

      MigrationRunner.replay!(@version)

      assert %{is_active: true, disabled_at: nil, disabled_reason: nil, failure_count: 0} =
               Repo.reload!(plan)

      assert %{is_active: false, disabled_reason: "too_many_failures", failure_count: 10} =
               Repo.reload!(other)

      assert %{is_active: false, disabled_reason: @plan_reason <> "."} = Repo.reload!(lookalike)
      assert %{is_active: false, disabled_at: nil} = Repo.reload!(paused)
      assert %{is_active: true} = Repo.reload!(active)
    end
  end
end

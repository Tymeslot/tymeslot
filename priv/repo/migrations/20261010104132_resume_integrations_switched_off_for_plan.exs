defmodule Tymeslot.Repo.Migrations.ResumeIntegrationsSwitchedOffForPlan do
  @moduledoc """
  Switches back on the Slack and Telegram integrations that were switched
  off only because their owner's plan stopped covering automations.

  Integrations used to be switched off, with the reason "Plan no longer
  permits automations", when a delivery ran after the plan lapsed. They
  now stay on and simply pause while the plan lacks automations, resuming
  when it covers them again, so rows switched off the old way are put back
  in the state they would be in now.

  Only rows with exactly that reason are touched. That write only ever
  switched off an integration that was active and not already disabled,
  so the plan is the sole reason these rows are off; a row its owner
  paused, or one disabled for anything else, keeps its state. An install
  whose plans never lapse has no such rows, and this does nothing there.

  Rolling back leaves the rows switched on.
  """

  use Ecto.Migration

  @reason "Plan no longer permits automations"

  def up do
    for table <- ~w(slack_integrations telegram_integrations) do
      # A one-shot repair of rows matched on a free-text column; an `UPDATE`
      # with a predicate has no migration DSL form.
      # excellent_migrations:safety-assured-for-next-line raw_sql_executed
      execute("""
      UPDATE #{table}
      SET is_active = true, disabled_at = NULL, disabled_reason = NULL, failure_count = 0
      WHERE disabled_reason = '#{@reason}'
      """)
    end
  end

  def down, do: :ok
end

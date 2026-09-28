defmodule Tymeslot.Workers.AdminAlertDigestWorker do
  @moduledoc """
  Sends the daily digest of info-severity admin alerts, from the crontab.

  The work is `Tymeslot.Infrastructure.AdminAlerts.Digest.deliver/0`: the
  waiting entries are handed to `Tymeslot.Workers.EmailWorker` as one email
  and deleted in the same transaction. A failed hand-off keeps the entries
  and returns an error, so this job retries; the email itself retries on the
  admin alert schedule inside the email worker.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  alias Tymeslot.Infrastructure.AdminAlerts.Digest

  @impl Oban.Worker
  def perform(_job), do: Digest.deliver()
end

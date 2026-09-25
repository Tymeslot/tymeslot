defmodule Tymeslot.Workers.DeliveryClaims.DeliveryClaimSchema do
  @moduledoc """
  One side effect an Oban job has claimed: the job's id and a key naming the
  effect within that job (a recipient, a channel message, a webhook post).

  Once Oban prunes the job, its claims can never be consulted again;
  `Tymeslot.Workers.ObanMaintenanceWorker` deletes them. There is no foreign
  key to `oban_jobs`, because a job run without being inserted
  (`Oban.Testing.perform_job/2`) still carries an id.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: integer() | nil,
          oban_job_id: integer() | nil,
          effect_key: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "job_delivery_claims" do
    field(:oban_job_id, :integer)
    field(:effect_key, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

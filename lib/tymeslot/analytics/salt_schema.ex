defmodule Tymeslot.Analytics.SaltSchema do
  @moduledoc """
  Ecto schema for the random per-UTC-day salt behind the analytics visitor
  hash (see `Tymeslot.Analytics.Fingerprint`).

  One row per UTC day, keyed by the date. A row is created on the first hash of
  its day and deleted by `Tymeslot.Workers.DataRetentionWorker` once the day is
  over, after which no hash made with it can be recomputed.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{date: Date.t() | nil, salt: binary() | nil}

  @primary_key {:date, :date, autogenerate: false}
  schema "analytics_salts" do
    field(:salt, :binary)
  end
end

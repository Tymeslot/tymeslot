defmodule Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema do
  @moduledoc """
  An admin alert waiting to be emailed with others: an info-severity alert
  waiting for the daily digest (`batch` `"daily"`), or an error alert held
  back by `Tymeslot.Infrastructure.AdminAlerts.ErrorBurst` for its roll-up
  (`"errors"`).

  One row per distinct alert: `alert_hash` is the alert's dedup hash, so a
  repeat before the next digest raises `occurrences` (and refreshes the
  message and metadata) instead of adding a row. `inserted_at` is when the
  alert was first seen, `updated_at` when it was last seen. `metadata` is the
  `PIIScrubber`-scrubbed copy, serialised to JSON-safe values.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          alert_type: String.t() | nil,
          category: String.t() | nil,
          message: String.t() | nil,
          metadata: map() | nil,
          alert_hash: String.t() | nil,
          occurrences: integer() | nil,
          batch: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "admin_alert_digest_entries" do
    field :alert_type, :string
    field :category, :string
    field :message, :string
    field :metadata, :map, default: %{}
    field :alert_hash, :string
    field :occurrences, :integer, default: 1
    field :batch, :string, default: "daily"

    timestamps(type: :utc_datetime_usec)
  end

  @required [:alert_type, :category, :message, :metadata, :alert_hash]
  @batches ~w(daily errors)

  @doc "The emails an entry can wait for: the daily digest and the error roll-up."
  @spec batches() :: [String.t()]
  def batches, do: @batches

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:batch | @required])
    |> validate_required(@required -- [:metadata])
    |> validate_inclusion(:batch, @batches)
  end
end

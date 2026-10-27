defmodule Tymeslot.Integrations.Calendar.SeriesRuleSchema do
  @moduledoc """
  The repeat rule of one Google or Outlook series an integration's cache
  holds occurrences of, read from the series' master.

  Both providers list a series as its single occurrences, none of which says
  how the series repeats, so the rule is fetched from the master apart from
  them (`Tymeslot.Integrations.Calendar.SeriesRules`) and copied onto each
  occurrence as it is cached (`Tymeslot.Integrations.Calendar.Sync`).

  `rule` is stored without its `RRULE:` prefix, as every cached rule is, and
  is nil when the master was read and found to be gone or not a series.
  `master_start` is the series' first start, which a `COUNT` is counted
  from; `fetched_at` says when the master was last read.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          calendar_integration_id: integer() | nil,
          provider_master_id: String.t() | nil,
          rule: String.t() | nil,
          master_start: DateTime.t() | nil,
          fetched_at: DateTime.t() | nil
        }

  schema "calendar_series_rules" do
    field(:provider_master_id, :string)
    field(:rule, :string)
    field(:master_start, :utc_datetime)
    field(:fetched_at, :utc_datetime)

    belongs_to(:calendar_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(series_rule, attrs) do
    series_rule
    |> cast(attrs, [
      :calendar_integration_id,
      :provider_master_id,
      :rule,
      :master_start,
      :fetched_at
    ])
    |> validate_required([:calendar_integration_id, :provider_master_id, :fetched_at])
    |> foreign_key_constraint(:calendar_integration_id)
    |> unique_constraint([:calendar_integration_id, :provider_master_id])
  end
end

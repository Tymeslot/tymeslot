defmodule Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema do
  @moduledoc """
  One configured mirroring relationship: events on the source integration get a
  placeholder written onto the target, so external tools booking against the
  target see the time as taken.

  Direction is modelled by rows rather than a `direction` column. A
  bidirectional relationship is two rows. Every row is then a single
  unambiguous source→target statement, "pause one direction" is expressible
  through `enabled`, and no reader has to work out which end of a row it is
  looking at.

  ## Why the target's provider arrives as a virtual field

  Two rules depend on what the target integration *is*, not on what the link
  says: a read-only subscription can never receive a mirror, and the CalDAV
  family ignores a calendar id on write and always lands on the primary path.
  Both are asked of `SyncLink.Capability`, which holds every provider
  asymmetry in one table; both need `calendar_integrations.provider`, which a
  changeset cannot read — it has no Repo access, and giving it one would make
  every validation a query.

  So the caller loads the target integration it is already holding and passes
  its provider in as `:target_provider`. The field is `virtual: true`: it
  shapes the changeset and is discarded, never stored. Storing it would create
  a second copy of a fact that lives on the integration row and could drift
  from it — a link would go on believing its target is writable long after the
  integration was reconnected as a subscription.

  Omitting `:target_provider` skips both rules rather than failing. The context
  always supplies it; a caller that does not is trusted to have checked, and
  the check constraint plus the engine's own provider guard remain as the last
  line. Same-user ownership of both integrations is likewise the context's job
  (`Appearance.with_owned_integration/3` is the pattern), since verifying it
  needs exactly the query a changeset cannot run.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  @privacy_tiers ~w(busy_only generic_label full_passthrough)

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          source_integration_id: integer() | nil,
          target_integration_id: integer() | nil,
          target_calendar_id: String.t() | nil,
          target_provider: String.t() | nil,
          privacy_tier: String.t(),
          generic_label: String.t() | nil,
          mirror_colour: String.t() | nil,
          enabled: boolean(),
          last_reconciled_at: DateTime.t() | nil,
          user: UserSchema.t() | Ecto.Association.NotLoaded.t(),
          source_integration:
            CalendarIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          target_integration:
            CalendarIntegrationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_sync_links" do
    field(:target_calendar_id, :string)
    field(:privacy_tier, :string, default: "busy_only")
    field(:generic_label, :string)
    field(:mirror_colour, :string)
    field(:enabled, :boolean, default: true)
    field(:last_reconciled_at, :utc_datetime_usec)

    # See the moduledoc: the target's provider shapes two validations and is
    # never stored, because the integration row already holds it.
    field(:target_provider, :string, virtual: true)

    belongs_to(:user, UserSchema)
    belongs_to(:source_integration, CalendarIntegrationSchema)
    belongs_to(:target_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the privacy tiers a link may be configured with.

  `busy_only` writes an opaque placeholder with no detail, `generic_label`
  writes the link's own `generic_label` as the title, and `full_passthrough`
  copies the source event's summary.
  """
  @spec privacy_tiers() :: [String.t()]
  def privacy_tiers, do: @privacy_tiers

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :user_id,
      :source_integration_id,
      :target_integration_id,
      :target_calendar_id,
      :target_provider,
      :privacy_tier,
      :generic_label,
      :mirror_colour,
      :enabled,
      :last_reconciled_at
    ])
    |> validate_required([:user_id, :source_integration_id, :target_integration_id])
    |> validate_not_self_link()
    |> validate_target_writable()
    |> clear_calendar_id_when_target_cannot_choose()
    |> validate_inclusion(:privacy_tier, @privacy_tiers)
    |> validate_colour()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:source_integration_id)
    |> foreign_key_constraint(:target_integration_id)
    |> check_constraint(:target_integration_id,
      name: :calendar_sync_links_no_self_link,
      message: "cannot mirror a calendar onto itself"
    )
    |> unique_constraint([:source_integration_id, :target_integration_id, :target_calendar_id],
      name: :calendar_sync_links_source_target_calendar_index,
      message: "has already been linked"
    )
  end

  # A link from an integration to itself would write every event back onto the
  # calendar it came from, and each write would look like a fresh source event
  # to the next sync. The database constraint catches it too; this reports it
  # on the field the form can render rather than as an insert failure.
  defp validate_not_self_link(changeset) do
    source = get_field(changeset, :source_integration_id)
    target = get_field(changeset, :target_integration_id)

    if not is_nil(source) and source == target do
      add_error(changeset, :target_integration_id, "cannot mirror a calendar onto itself")
    else
      changeset
    end
  end

  # A subscription is a published feed: `create_event` returns
  # {:error, :read_only}, so a link naming one as its target would be accepted
  # here and then fail on every single mirror write forever. Rejecting it at
  # configuration time is the only point where the organiser can act on it.
  defp validate_target_writable(changeset) do
    case get_field(changeset, :target_provider) do
      nil ->
        changeset

      provider ->
        if Capability.supports?(provider, :mirror_target) do
          changeset
        else
          add_error(
            changeset,
            :target_integration_id,
            "is a read-only subscription and cannot receive mirrored events"
          )
        end
    end
  end

  # The CalDAV family ignores a :calendar_id in the event payload and always
  # writes to the primary calendar path. Storing a calendar id for such a
  # target would record a choice the engine cannot honour, and the dashboard
  # would go on displaying it as though mirrors were landing there.
  #
  # Gated on `:mirror_target` first, and not merely as a shortcut. A target that
  # cannot be written to at all answers `false` to `:target_calendar_choice`
  # too, so asking only the second question would start nulling the field out
  # for a subscription target — a changeset `validate_target_writable/1` has
  # already rejected, whose stored values nobody should be quietly rewriting on
  # the way to reporting the error.
  defp clear_calendar_id_when_target_cannot_choose(changeset) do
    provider = get_field(changeset, :target_provider)

    if Capability.supports?(provider, :mirror_target) and
         not Capability.supports?(provider, :target_calendar_choice) do
      put_change(changeset, :target_calendar_id, nil)
    else
      changeset
    end
  end

  # nil is a valid colour and means "inherit the target integration's".
  # Anything else must be a palette key, so a value from outside the picker
  # cannot reach the grid and resolve to a Tailwind class that was never
  # generated.
  defp validate_colour(changeset) do
    validate_change(changeset, :mirror_colour, fn :mirror_colour, value ->
      if is_nil(value) or EventColour.valid_key?(value) do
        []
      else
        [mirror_colour: "is not a palette colour"]
      end
    end)
  end
end

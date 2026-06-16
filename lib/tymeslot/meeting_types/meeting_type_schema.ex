defmodule Tymeslot.MeetingTypes.MeetingTypeSchema do
  @moduledoc """
  Schema for meeting types that users can configure.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          duration_minutes: integer() | nil,
          icon: String.t() | nil,
          is_active: boolean(),
          is_private: boolean(),
          slug: String.t() | nil,
          allow_video: boolean(),
          sort_order: integer(),
          reminder_config: [map()],
          payment_required: boolean(),
          price_cents: integer() | nil,
          is_archived: boolean(),
          custom_fields: [FieldDefinition.t()],
          user_id: integer() | nil,
          video_integration_id: integer() | nil,
          calendar_integration_id: integer() | nil,
          target_calendar_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "meeting_types" do
    field(:name, :string)
    field(:description, :string)
    field(:duration_minutes, :integer)
    field(:icon, :string)
    field(:is_active, :boolean, default: true)
    field(:is_private, :boolean, default: false)
    field(:slug, :string)
    field(:allow_video, :boolean, default: false)
    field(:sort_order, :integer, default: 0)
    field(:target_calendar_id, :string)
    field(:reminder_config, {:array, :map}, default: nil)
    field(:payment_required, :boolean, default: false)
    field(:price_cents, :integer)
    field(:is_archived, :boolean, default: false)

    belongs_to(:user, Tymeslot.Auth.UserSchema)
    belongs_to(:video_integration, Tymeslot.Integrations.Video.VideoIntegrationSchema)
    belongs_to(:calendar_integration, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema)

    embeds_many(:custom_fields, FieldDefinition, on_replace: :delete)

    timestamps()
  end

  @valid_icons [
    "none",
    "hero-bolt",
    "hero-chat-bubble-left-right",
    "hero-hand-raised",
    "hero-chart-bar",
    "hero-flag",
    "hero-clock",
    "hero-phone",
    "hero-light-bulb",
    "hero-wrench-screwdriver",
    "hero-book-open",
    "hero-rocket-launch",
    "hero-beaker"
  ]

  # A custom booking slug: lowercase letters, digits and single hyphens.
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # Reserved because the URL layer rewrites "<n>min" into "<n>-minutes" for
  # legacy duration links, which would break round-tripping of such a slug.
  @reserved_slug_format ~r/^\d+min$/
  @slug_max_length 80

  @doc """
  Changeset for creating/updating meeting types.

  Payment-related validation is performed when `payment_required` is true.
  Because the host's payment context lives in a separate domain, callers
  pass it in via `opts`:

    * `:host_charges_enabled` (default `false`) — whether the host's Stripe
      Connect account can accept charges.
    * `:currency` (default `"usd"`) — the host's pricing currency, used only
      to format the minimum-charge error message in major units.
    * `:currency_minimum_cents` (default `50`) — minimum charge amount in
      cents for the host's currency. Callers should retrieve this via
      `Tymeslot.MeetingPayments.currency_minimum_cents/1`.
  """
  @spec changeset(Ecto.Schema.t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(meeting_type, attrs, opts \\ []) do
    meeting_type
    |> cast(attrs, [
      :name,
      :description,
      :duration_minutes,
      :icon,
      :is_active,
      :is_private,
      :slug,
      :allow_video,
      :sort_order,
      :user_id,
      :video_integration_id,
      :calendar_integration_id,
      :target_calendar_id,
      :reminder_config,
      :payment_required,
      :price_cents,
      :is_archived
    ])
    |> cast_embed(:custom_fields, with: &FieldDefinition.changeset/2)
    |> validate_required([:name, :duration_minutes, :user_id])
    |> validate_length(:name, Constraints.name_length_opts())
    |> validate_length(:description, max: Constraints.description_max_length())
    |> validate_number(:duration_minutes, Constraints.duration_minutes_opts())
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_inclusion(:icon, @valid_icons, message: "must be one of the available icons")
    |> normalize_slug()
    |> validate_slug()
    |> validate_video_integration()
    |> validate_calendar_destination()
    |> validate_reminder_config()
    |> validate_payment_fields(opts)
    |> unique_constraint([:user_id, :name],
      message: "You already have a meeting type with this name"
    )
    |> unique_constraint([:user_id, :slug],
      name: :meeting_types_user_id_slug_index,
      message: "is already taken"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:video_integration_id)
    |> foreign_key_constraint(:calendar_integration_id)
  end

  @doc """
  Simple changeset for toggling active status.
  Only validates the is_active field without checking video integration requirements.
  """
  @spec toggle_active_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def toggle_active_changeset(meeting_type, attrs) do
    cast(meeting_type, attrs, [:is_active])
  end

  @doc """
  Focused changeset for toggling private visibility, without re-validating
  unrelated fields (e.g. video integration).
  """
  @spec visibility_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def visibility_changeset(meeting_type, attrs) do
    cast(meeting_type, attrs, [:is_private])
  end

  @doc """
  Focused changeset for setting/clearing the custom booking slug, without
  re-validating unrelated fields. Applies the same normalisation, format rules
  and uniqueness constraint as the full changeset.
  """
  @spec slug_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def slug_changeset(meeting_type, attrs) do
    meeting_type
    |> cast(attrs, [:slug])
    |> normalize_slug()
    |> validate_slug()
    |> unique_constraint([:user_id, :slug],
      name: :meeting_types_user_id_slug_index,
      message: "is already taken"
    )
  end

  # An empty/blank custom slug means "derive the slug from the name", stored as
  # NULL. Otherwise trim and downcase so the stored slug is URL-canonical.
  defp normalize_slug(changeset) do
    update_change(changeset, :slug, fn
      nil ->
        nil

      slug when is_binary(slug) ->
        case slug |> String.trim() |> String.downcase() do
          "" -> nil
          normalized -> normalized
        end
    end)
  end

  # Only a newly supplied (non-nil) slug needs format checking — clearing it to
  # NULL or leaving it untouched is always valid.
  defp validate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        changeset

      slug ->
        cond do
          String.length(slug) > @slug_max_length ->
            add_error(changeset, :slug, "is too long")

          Regex.match?(@reserved_slug_format, slug) ->
            add_error(changeset, :slug, "is reserved")

          not Regex.match?(@slug_format, slug) ->
            add_error(changeset, :slug, "may only contain lowercase letters, numbers and hyphens")

          true ->
            changeset
        end
    end
  end

  # Validate that video integration is set when allow_video is true
  defp validate_video_integration(changeset) do
    allow_video = get_field(changeset, :allow_video)
    video_integration_id = get_field(changeset, :video_integration_id)

    if allow_video && is_nil(video_integration_id) do
      add_error(changeset, :video_integration_id, "is required when video meetings are enabled")
    else
      changeset
    end
  end

  # Validate that target calendar is set when calendar integration is chosen
  defp validate_calendar_destination(changeset) do
    integration_id = get_field(changeset, :calendar_integration_id)
    target_id = get_field(changeset, :target_calendar_id)

    case {integration_id, target_id} do
      {id, nil} when is_integer(id) ->
        add_error(
          changeset,
          :target_calendar_id,
          "is required when a calendar integration is selected"
        )

      {nil, tid} when is_binary(tid) ->
        add_error(
          changeset,
          :calendar_integration_id,
          "is required when a target calendar is selected"
        )

      _other ->
        changeset
    end
  end

  defp validate_reminder_config(changeset) do
    case get_change(changeset, :reminder_config) do
      nil ->
        changeset

      reminders when is_list(reminders) ->
        validate_reminder_list(changeset, reminders)

      _other ->
        add_error(changeset, :reminder_config, "must be a list of reminder settings")
    end
  end

  defp validate_reminder_list(changeset, reminders) do
    if length(reminders) > 3 do
      add_error(changeset, :reminder_config, "cannot have more than 3 reminders")
    else
      {errors, normalized} =
        reminders
        |> Enum.map(&ReminderUtils.normalize_reminder/1)
        |> Enum.split_with(&match?({:error, _reason}, &1))

      if errors != [] do
        add_error(changeset, :reminder_config, "contains invalid reminder settings")
      else
        reminders = Enum.map(normalized, fn {:ok, reminder} -> reminder end)

        if ReminderUtils.duplicate_reminders?(reminders) do
          add_error(changeset, :reminder_config, "contains duplicate reminders")
        else
          changeset
        end
      end
    end
  end

  defp validate_payment_fields(changeset, opts) do
    if get_field(changeset, :payment_required) do
      changeset
      |> validate_required([:price_cents])
      |> validate_charges_enabled(opts)
      |> validate_currency_minimum(opts)
    else
      changeset
    end
  end

  defp validate_charges_enabled(changeset, opts) do
    if Keyword.get(opts, :host_charges_enabled, false) do
      changeset
    else
      add_error(changeset, :payment_required, "Stripe must be connected")
    end
  end

  defp validate_currency_minimum(changeset, opts) do
    minimum = Keyword.get(opts, :currency_minimum_cents, 50)
    currency = Keyword.get(opts, :currency, "usd")

    validate_number(changeset, :price_cents,
      greater_than_or_equal_to: minimum,
      message: "must be at least #{format_minimum(minimum, currency)}"
    )
  end

  # Mirrors the minimum hint shown beside the price input (e.g. "EUR 0.50"),
  # so the validation error speaks in major units rather than raw cents.
  defp format_minimum(cents, currency) do
    "#{String.upcase(currency)} #{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end

  @doc """
  Returns the list of valid icons for meeting types.
  """
  @spec valid_icons() :: [String.t()]
  def valid_icons, do: @valid_icons

  @doc """
  Returns the list of valid icons with their display names.
  """
  @spec valid_icons_with_names() :: [{String.t(), String.t()}]
  def valid_icons_with_names do
    [
      {"none", "No Icon"},
      {"hero-bolt", "Lightning - Quick meetings"},
      {"hero-chat-bubble-left-right", "Chat - Discussion meetings"},
      {"hero-hand-raised", "Hand - Business meetings"},
      {"hero-chart-bar", "Chart - Analysis meetings"},
      {"hero-flag", "Flag - Strategic meetings"},
      {"hero-clock", "Clock - Scheduled meetings"},
      {"hero-phone", "Phone - Call meetings"},
      {"hero-light-bulb", "Light Bulb - Brainstorming"},
      {"hero-wrench-screwdriver", "Wrench - Technical meetings"},
      {"hero-book-open", "Book - Learning meetings"},
      {"hero-rocket-launch", "Rocket - Project meetings"},
      {"hero-beaker", "Beaker - Casual meetings"}
    ]
  end
end

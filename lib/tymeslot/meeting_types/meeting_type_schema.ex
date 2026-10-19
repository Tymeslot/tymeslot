defmodule Tymeslot.MeetingTypes.MeetingTypeSchema do
  @moduledoc """
  Schema for meeting types that users can configure.
  """
  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset
  import Tymeslot.ChangesetValidators.BookingLimits, only: [validate_booking_limits: 2]

  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingTypes.GroupLocationRule
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeAttachment
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          duration_minutes: integer() | nil,
          slot_interval_minutes: integer() | nil,
          icon: String.t() | nil,
          is_active: boolean(),
          is_private: boolean(),
          slug: String.t() | nil,
          show_as_free: boolean(),
          allow_video: boolean(),
          allow_guests: boolean(),
          sort_order: integer(),
          reminder_config: [map()],
          payment_required: boolean(),
          price_cents: integer() | nil,
          max_participants: integer(),
          show_seat_availability: boolean(),
          last_spots_threshold: pos_integer() | nil,
          requires_approval: boolean(),
          approval_window_hours: pos_integer() | nil,
          is_archived: boolean(),
          max_bookings_per_day: pos_integer() | nil,
          max_bookings_per_week: pos_integer() | nil,
          max_bookings_per_month: pos_integer() | nil,
          custom_fields: [FieldDefinition.t()],
          locations: [LocationOption.t()],
          attachments: [MeetingTypeAttachment.t()],
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
    field(:slot_interval_minutes, :integer)
    field(:icon, :string)
    field(:is_active, :boolean, default: true)
    field(:is_private, :boolean, default: false)
    field(:slug, :string)
    field(:show_as_free, :boolean, default: false)
    field(:allow_video, :boolean, default: false)
    field(:allow_guests, :boolean, default: false)
    field(:sort_order, :integer, default: 0)
    field(:target_calendar_id, :string)
    field(:reminder_config, {:array, :map}, default: nil)
    field(:payment_required, :boolean, default: false)
    field(:price_cents, :integer)
    field(:max_participants, :integer, default: 1)
    field(:show_seat_availability, :boolean, default: true)
    field(:last_spots_threshold, :integer)

    # Bookings on this meeting type are held until the host approves them,
    # rather than confirmed on submission. `approval_window_hours` nil means
    # "use `Constraints.default_approval_window_hours/0`", the same way a nil
    # `availability_schedule_id` means "use the profile default".
    field(:requires_approval, :boolean, default: false)
    field(:approval_window_hours, :integer)
    field(:is_archived, :boolean, default: false)
    field(:max_bookings_per_day, :integer)
    field(:max_bookings_per_week, :integer)
    field(:max_bookings_per_month, :integer)

    belongs_to(:user, Tymeslot.Auth.UserSchema)
    belongs_to(:video_integration, Tymeslot.Integrations.Video.VideoIntegrationSchema)
    belongs_to(:calendar_integration, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema)

    belongs_to(
      :availability_schedule,
      Tymeslot.Availability.AvailabilityScheduleSchema
    )

    embeds_many(:custom_fields, FieldDefinition, on_replace: :delete)
    embeds_many(:attachments, MeetingTypeAttachment, on_replace: :delete)

    # Where this meeting type can be held. One entry states the location;
    # two or more make the booker choose. `allow_video` and
    # `video_integration_id` above are kept as a projection of this list
    # (see `project_video_fields/1`), so the many readers that only ask
    # "does this type do video, and on which integration" keep working.
    embeds_many(:locations, LocationOption, on_replace: :delete)

    timestamps(type: :utc_datetime)
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
    "hero-beaker",
    "hero-building-office-2",
    "hero-map-pin",
    "hero-video-camera",
    "hero-globe-alt"
  ]

  # A custom booking slug: lowercase letters, digits and single hyphens.
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # Reserved because the URL layer rewrites "<n>min" into "<n>-minutes" for
  # legacy duration links, which would break round-tripping of such a slug.
  @reserved_slug_format ~r/^\d+min$/
  # Reserved because `/:username/poll/:token` (the public poll voting page) would
  # otherwise shadow `/:username/poll/book` for a meeting type slugged "poll".
  @reserved_slugs ~w(poll)
  @slug_max_length 80

  @doc """
  Changeset for creating/updating meeting types.

  Payment-related validation is performed when `payment_required` is true.
  Because the host's payment context lives in a separate domain, callers
  pass it in via `opts`:

    * `:host_charges_enabled` (default `false`) — whether the host's Stripe
      Connect account can accept charges.
    * `:price_settable` (default `false`) — whether the host may set or
      change a price (`Tymeslot.MeetingPayments.price_settable?/1`). Without
      it, turning payment on or changing a price is refused; turning payment
      off is not.
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
      :slot_interval_minutes,
      :icon,
      :is_active,
      :is_private,
      :slug,
      :show_as_free,
      :allow_video,
      :allow_guests,
      :sort_order,
      :user_id,
      :video_integration_id,
      :calendar_integration_id,
      :availability_schedule_id,
      :target_calendar_id,
      :reminder_config,
      :payment_required,
      :price_cents,
      :max_participants,
      :show_seat_availability,
      :last_spots_threshold,
      :requires_approval,
      :approval_window_hours,
      :is_archived,
      :max_bookings_per_day,
      :max_bookings_per_week,
      :max_bookings_per_month
    ])
    |> cast_embed(:custom_fields, with: &FieldDefinition.changeset/2)
    |> cast_embed(:attachments, with: &MeetingTypeAttachment.changeset/2)
    |> cast_embed(:locations, with: &LocationOption.changeset/2)
    |> validate_locations()
    |> project_video_fields()
    |> validate_required([:name, :duration_minutes, :user_id])
    |> validate_length(:name, Constraints.name_length_opts())
    |> validate_length(:description, max: Constraints.description_max_length())
    |> validate_numbers()
    |> validate_booking_limits(:meeting_types)
    |> validate_inclusion(:icon, @valid_icons,
      message: dgettext_noop("errors", "must be one of the available icons")
    )
    |> normalize_slug()
    |> validate_slug()
    |> validate_video_integration()
    |> validate_calendar_destination()
    |> ReminderValidation.validate_changeset()
    |> validate_payment_fields(opts)
    |> validate_group_rules()
    |> unique_constraint([:user_id, :name],
      error_key: :name,
      message: dgettext_noop("errors", "You already have a meeting type with this name")
    )
    |> unique_constraint([:user_id, :slug],
      name: :meeting_types_user_id_slug_index,
      message: dgettext_noop("errors", "is already taken")
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:video_integration_id)
    |> foreign_key_constraint(:calendar_integration_id)
    |> foreign_key_constraint(:availability_schedule_id)
  end

  defp validate_numbers(changeset) do
    changeset
    |> validate_number(:duration_minutes, Constraints.duration_minutes_opts())
    |> validate_duration_step()
    |> validate_number(:slot_interval_minutes, Constraints.slot_interval_minutes_opts())
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_number(:max_participants, Constraints.max_participants_opts())
    |> validate_number(:last_spots_threshold, Constraints.last_spots_threshold_opts())
    |> validate_number(:approval_window_hours, Constraints.approval_window_hours_opts())
  end

  @doc """
  A changeset taking `venue_id` off every in-person location that lists it,
  for a venue being deleted. The remaining venues keep their order, and
  every other location, and every other field of the rewritten ones, is
  kept exactly as stored. The meeting type's own validation does not run:
  nothing else it checks changes, and a location listing no venue is valid
  for a one-to-one type.

  A group type is the exception: its address is fixed in advance
  (`Tymeslot.MeetingTypes.GroupLocationRule`), so a location whose only
  venue this is would be left invalid, and the changeset carries an error
  on `:locations` instead. Only the violation this rewrite would create is
  checked, so a venue can still be taken off a group type that lists it
  among several.
  """
  @spec without_venue_changeset(t(), integer()) :: Ecto.Changeset.t()
  def without_venue_changeset(%__MODULE__{locations: locations} = meeting_type, venue_id)
      when is_integer(venue_id) do
    locations =
      Enum.map(locations, fn
        %LocationOption{kind: "in_person", venue_ids: ids} = location ->
          %{location | venue_ids: Enum.reject(ids, &(&1 == venue_id))}

        location ->
          location
      end)

    changeset = meeting_type |> change() |> put_embed(:locations, locations)

    if group?(meeting_type) and left_without_venue?(meeting_type, venue_id),
      do: add_error(changeset, :locations, group_location_message(:address_after_booking)),
      else: changeset
  end

  @doc """
  Whether taking `venue_id` off the meeting type's locations would leave one
  of them in person with no venue: a location whose only venue it is.
  """
  @spec left_without_venue?(t(), integer()) :: boolean()
  def left_without_venue?(%__MODULE__{locations: locations}, venue_id) do
    Enum.any?(locations, fn
      %LocationOption{kind: "in_person", venue_ids: [^venue_id]} -> true
      _location -> false
    end)
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
      message: dgettext_noop("errors", "is already taken")
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

  # Only on a changed duration, so a type saved before the rule keeps saving.
  defp validate_duration_step(changeset) do
    step = Constraints.duration_step_minutes()
    message = {dgettext_noop("errors", "must be a multiple of %{step} minutes"), step: step}

    validate_change(changeset, :duration_minutes, fn :duration_minutes, minutes ->
      if is_integer(minutes) and rem(minutes, step) != 0,
        do: [duration_minutes: message],
        else: []
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
            add_error(changeset, :slug, dgettext_noop("errors", "is too long"))

          Regex.match?(@reserved_slug_format, slug) or slug in @reserved_slugs ->
            add_error(changeset, :slug, "is reserved")

          not Regex.match?(@slug_format, slug) ->
            add_error(
              changeset,
              :slug,
              dgettext_noop("errors", "may only contain lowercase letters, numbers and hyphens")
            )

          true ->
            changeset
        end
    end
  end

  # A meeting type has to be held somewhere. Only checked when the caller
  # actually supplied a list: a changeset that never casts `locations`
  # (toggling `is_active`, renaming, the attachment paths) must not fail on a
  # list it was not asked to touch.
  #
  # The presence of the key is read from `params` rather than from `changes`,
  # because casting an empty list over an already-empty embed produces no
  # change at all, and "the caller sent nothing" and "the caller sent
  # nothing *left*" are exactly the two cases that have to be told apart.
  defp validate_locations(changeset) do
    supplied? = Map.has_key?(changeset.params || %{}, "locations")

    if supplied? and get_field(changeset, :locations) == [] do
      add_error(
        changeset,
        :locations,
        dgettext_noop("errors", "must include at least one location")
      )
    else
      changeset
    end
  end

  # `allow_video` / `video_integration_id` are derived, never independently
  # authored: they answer "can this type produce a video room, and on which
  # integration" for every caller that predates the list. The first video
  # option wins, and within it the first provider, matching the room a
  # booker who changes nothing would get.
  #
  # Only applied when `locations` is part of the changeset, so a changeset
  # that does not touch the list leaves the pair exactly as it found it.
  defp project_video_fields(%{changes: %{locations: _locations}} = changeset) do
    changeset
    |> get_field(:locations)
    |> Enum.find(&(&1.kind == "video"))
    |> apply_video_projection(changeset)
  end

  defp project_video_fields(changeset), do: changeset

  defp apply_video_projection(%LocationOption{video_integration_ids: [id | _rest]}, changeset) do
    changeset
    |> put_change(:allow_video, true)
    |> put_change(:video_integration_id, id)
  end

  defp apply_video_projection(nil, changeset) do
    changeset
    |> put_change(:allow_video, false)
    |> put_change(:video_integration_id, nil)
  end

  # Validate that video integration is set when allow_video is true
  defp validate_video_integration(changeset) do
    allow_video = get_field(changeset, :allow_video)
    video_integration_id = get_field(changeset, :video_integration_id)

    if allow_video && is_nil(video_integration_id) do
      add_error(
        changeset,
        :video_integration_id,
        dgettext_noop("errors", "is required when video meetings are enabled")
      )
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
          dgettext_noop("errors", "is required when a calendar integration is selected")
        )

      {nil, tid} when is_binary(tid) ->
        add_error(
          changeset,
          :calendar_integration_id,
          dgettext_noop("errors", "is required when a target calendar is selected")
        )

      _other ->
        changeset
    end
  end

  defp validate_payment_fields(changeset, opts) do
    changeset = validate_price_settable(changeset, opts)

    if get_field(changeset, :payment_required) do
      changeset
      |> validate_required([:price_cents])
      |> validate_currency_minimum(opts)
    else
      changeset
    end
  end

  # Asked when the host asks for payment or sets a price, not every time they
  # touch a meeting type that already has one. A paid type keeps its price
  # while it cannot be edited (Stripe disconnected, or an account in a legacy
  # currency that checkout still charges), so that it resumes as it was (see
  # `Tymeslot.MeetingTypes.FormMapper.build_attrs/3`); reading the stored
  # `true` with `get_field` would then fail every unrelated save, on a field
  # the form cannot render in that state. Turning payment off, which clears
  # the price, stays open.
  defp validate_price_settable(changeset, opts) do
    cond do
      Keyword.get(opts, :price_settable, false) ->
        changeset

      not price_edit?(changeset) ->
        changeset

      Keyword.get(opts, :host_charges_enabled, false) ->
        add_error(
          changeset,
          :payment_required,
          dgettext_noop("errors", "Prices cannot be set in your Stripe account's currency")
        )

      true ->
        add_error(
          changeset,
          :payment_required,
          dgettext_noop("errors", "Stripe must be connected")
        )
    end
  end

  defp price_edit?(changeset) do
    get_change(changeset, :payment_required) == true or
      (changed?(changeset, :price_cents) and not is_nil(get_field(changeset, :price_cents)))
  end

  defp validate_currency_minimum(changeset, opts) do
    minimum = Keyword.get(opts, :currency_minimum_cents, 50)
    currency = Keyword.get(opts, :currency, "usd")

    validate_number(changeset, :price_cents,
      greater_than_or_equal_to: minimum,
      message:
        dgettext("errors", "must be at least %{minimum}",
          minimum: Money.format(minimum, currency)
        )
    )
  end

  # What a group type (more than one participant per slot) cannot also be.
  # Everyone in a group slot shares one meeting row, so nothing about that
  # row may be decided per booker:
  #
  #   * payment: per-seat payment is out of scope;
  #   * approval: the approval flow answers one booker's request for a whole
  #     meeting, and a shared slot has no single booker to answer;
  #   * the location: see `GroupLocationRule`.
  #
  # Read with `get_field/2` so a change to either side (the limit, or the
  # other setting) is caught.
  #
  # The messages are msgids of the `errors` domain, registered here with
  # `dgettext_noop/2` and translated where the form shows them, like Ecto's
  # own validator messages (`TymeslotWeb.Gettext.EctoErrorMsgids`).
  defp validate_group_rules(changeset) do
    if group_limit?(get_field(changeset, :max_participants)) do
      changeset
      |> refuse_for_group(
        :payment_required,
        dgettext_noop("errors", "group bookings cannot require payment")
      )
      |> refuse_for_group(
        :requires_approval,
        dgettext_noop("errors", "group bookings cannot require approval")
      )
      |> validate_group_location()
    else
      changeset
    end
  end

  defp group_limit?(max), do: is_integer(max) and max > 1

  defp refuse_for_group(changeset, field, message) do
    if get_field(changeset, field) == true,
      do: add_error(changeset, :max_participants, message),
      else: changeset
  end

  # The effective options, including the single fallback option a type with
  # no stored list offers, so a group type cannot slip through on the
  # "address arranged after booking" fallback.
  defp validate_group_location(changeset) do
    offered = %{
      locations: get_field(changeset, :locations),
      allow_video: get_field(changeset, :allow_video),
      video_integration_id: get_field(changeset, :video_integration_id)
    }

    case GroupLocationRule.check_meeting_type(offered) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :locations, group_location_message(reason))
    end
  end

  defp group_location_message(:not_single_location),
    do: dgettext_noop("errors", "a group meeting type must offer exactly one location")

  defp group_location_message(:provider_choice),
    do: dgettext_noop("errors", "a group meeting type's video call must use exactly one provider")

  defp group_location_message(:venue_choice),
    do:
      dgettext_noop(
        "errors",
        "a group meeting type's in-person location must name exactly one venue"
      )

  defp group_location_message(:address_after_booking),
    do: dgettext_noop("errors", "a group meeting type's in-person location must name a venue")

  defp group_location_message(:booker_phone),
    do:
      dgettext_noop(
        "errors",
        "a group meeting type cannot ask each booker for their phone number"
      )

  @doc """
  True when the meeting type accepts more than one participant per slot.

  Anything that is not a stored meeting type (`nil` before one is resolved,
  or the plain maps a demo organiser's synthesised types are) is not a group
  type: group bookings need the seat machinery behind a stored type.
  """
  @spec group?(t() | map() | nil) :: boolean()
  def group?(%__MODULE__{max_participants: max}) when is_integer(max) and max > 1, do: true
  def group?(_not_a_group_type), do: false

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
      {"hero-beaker", "Beaker - Casual meetings"},
      {"hero-building-office-2", "Building - In-person meetings"},
      {"hero-map-pin", "Map pin - On-location meetings"},
      {"hero-video-camera", "Video camera - Online meetings"},
      {"hero-globe-alt", "Globe - Remote meetings"}
    ]
  end
end

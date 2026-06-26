defmodule Tymeslot.MeetingTypes do
  @moduledoc """
  Context for managing meeting types.
  """
  alias Tymeslot.Features
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingTypes.Attachments
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Utils.UriUtils
  require Logger

  @doc """
  Gets all active meeting types for a user, creating defaults if none exist.
  """
  @spec get_active_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_active_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user", user_id: user_id)
        create_default_meeting_types(user_id)
        MeetingTypeQueries.list_active_meeting_types(user_id)

      true ->
        MeetingTypeQueries.list_active_meeting_types(user_id)
    end
  end

  @doc """
  Gets all meeting types for a user (active and inactive).
  """
  @spec get_all_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_all_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user", user_id: user_id)
        create_default_meeting_types(user_id)
        MeetingTypeQueries.list_all_meeting_types(user_id)

      true ->
        MeetingTypeQueries.list_all_meeting_types(user_id)
    end
  end

  @doc """
  Gets the publicly listed meeting types for a user (active and not private),
  creating defaults if none exist. This feeds the public booking overview;
  private types are excluded and reachable only by their direct link.
  """
  @spec get_public_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_public_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user", user_id: user_id)
        create_default_meeting_types(user_id)
        MeetingTypeQueries.list_public_meeting_types(user_id)

      true ->
        MeetingTypeQueries.list_public_meeting_types(user_id)
    end
  end

  @doc """
  Gets a meeting type by ID and user ID.
  """
  @spec get_meeting_type(integer(), integer()) :: Ecto.Schema.t() | nil
  def get_meeting_type(id, user_id) do
    MeetingTypeQueries.get_meeting_type(id, user_id)
  end

  @doc """
  Creates a new meeting type.

  `opts` are forwarded to the changeset for payment-validation context.
  """
  @spec create_meeting_type(map(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_meeting_type(attrs, opts \\ []) do
    with {:ok, meeting_type} <- MeetingTypeQueries.create_meeting_type(attrs, opts) do
      maybe_publish_booking_page(meeting_type)
      {:ok, meeting_type}
    end
  end

  # A host's booking page is "published" the first time they have a username set
  # and an active meeting type. Emit the telemetry once per host — the guard
  # lives in Profiles.mark_booking_page_published/1, which returns
  # {:ok, :published} only on the transition.
  defp maybe_publish_booking_page(%{user_id: user_id}) do
    with {:ok, profile} <- Profiles.get_or_create_profile(user_id),
         {:ok, :published} <- Profiles.mark_booking_page_published(profile) do
      :telemetry.execute([:tymeslot, :booking_page, :published], %{count: 1}, %{
        theme: profile.booking_theme
      })
    else
      _other -> :ok
    end
  end

  @doc """
  Updates a meeting type.

  `opts` are forwarded to the changeset for payment-validation context.
  """
  @spec update_meeting_type(Ecto.Schema.t(), map(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update_meeting_type(meeting_type, attrs, opts \\ []) do
    MeetingTypeQueries.update_meeting_type(meeting_type, attrs, opts)
  end

  @doc """
  Appends a host-uploaded attachment to a meeting type. See
  `Tymeslot.MeetingTypes.Attachments.add_attachment/2`.
  """
  defdelegate add_attachment(meeting_type, metadata), to: Attachments

  @doc """
  Removes an attachment from a meeting type. See
  `Tymeslot.MeetingTypes.Attachments.remove_attachment/2`.
  """
  defdelegate remove_attachment(meeting_type, attachment_id), to: Attachments

  @doc """
  Toggles the active status of a meeting type without validating video integration.
  """
  @spec toggle_meeting_type_status(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_meeting_type_status(meeting_type, attrs) do
    MeetingTypeQueries.toggle_meeting_type_status(meeting_type, attrs)
  end

  @doc """
  Deletes a meeting type.
  """
  @spec delete_meeting_type(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete_meeting_type(meeting_type) do
    MeetingTypeQueries.delete_meeting_type(meeting_type)
  end

  @doc """
  Sets whether a meeting type is private. A private type is excluded from the
  organiser's public booking page but stays reachable by its direct link.
  """
  @spec set_private(Ecto.Schema.t(), boolean()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def set_private(meeting_type, is_private) when is_boolean(is_private) do
    MeetingTypeQueries.set_visibility(meeting_type, %{is_private: is_private})
  end

  @doc """
  Toggles the active status of a meeting type.
  """
  @spec toggle_meeting_type(integer(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def toggle_meeting_type(id, user_id) do
    case get_meeting_type(id, user_id) do
      nil ->
        {:error, :not_found}

      meeting_type ->
        update_meeting_type(meeting_type, %{is_active: !meeting_type.is_active})
    end
  end

  @doc """
  Reorders meeting types for a user.
  """
  @spec reorder_meeting_types(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_meeting_types(user_id, meeting_type_ids) when is_list(meeting_type_ids) do
    MeetingTypeQueries.reorder_meeting_types(user_id, meeting_type_ids)
  end

  # Slug resolution and custom-slug management live in the focused sibling
  # module Tymeslot.MeetingTypes.Slugs; these delegations keep the context's
  # public API stable.
  defdelegate find_by_slug(user_id, slug), to: Slugs
  defdelegate effective_slug(meeting_type), to: Slugs
  defdelegate to_slug(meeting_type), to: Slugs
  defdelegate to_duration_string(meeting_type), to: Slugs
  defdelegate generate_random_slug(user_id), to: Slugs
  defdelegate normalize_slug(slug), to: Slugs
  defdelegate update_slug(meeting_type, slug), to: Slugs

  @doc """
  Normalizes duration inputs into the slug format used in URLs.
  """
  @spec normalize_duration_slug(String.t() | nil) :: String.t() | nil
  def normalize_duration_slug(nil), do: nil

  def normalize_duration_slug(duration) when is_binary(duration) do
    case Regex.run(~r/^(\d+)min$/, duration) do
      [_match, minutes] -> "#{minutes}-minutes"
      _no_match -> duration
    end
  end

  @doc """
  Finds a meeting type by duration string (now deprecated in favor of find_by_slug).
  """
  @spec find_by_duration_string(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_duration_string(user_id, slug) do
    find_by_slug(user_id, slug)
  end

  @doc """
  Validates that a duration has been selected from available meeting types.
  Used in booking workflow validation.
  """
  @spec validate_duration_selection(String.t() | nil, [Ecto.Schema.t()]) ::
          :ok | {:error, String.t()}
  def validate_duration_selection(nil, _available_types),
    do: {:error, "Please select a meeting duration"}

  def validate_duration_selection("", _available_types),
    do: {:error, "Please select a meeting duration"}

  def validate_duration_selection(duration, available_types) when is_list(available_types) do
    if duration_valid?(duration, available_types) do
      :ok
    else
      {:error, "Invalid meeting duration selected"}
    end
  end

  def validate_duration_selection(_duration, _available_types),
    do: {:error, "Please select a meeting duration"}

  @doc """
  Checks if a duration is valid against available meeting types.
  """
  @spec duration_valid?(any(), any()) :: boolean()
  def duration_valid?(duration, available_types)
      when is_binary(duration) and is_list(available_types) do
    Enum.any?(available_types, fn meeting_type ->
      to_duration_string(meeting_type) == duration
    end)
  end

  def duration_valid?(_duration, _available_types), do: false

  @doc """
  Lists all meeting types for a user.
  """
  @spec list_meeting_types(integer()) :: [Ecto.Schema.t()]
  def list_meeting_types(user_id) do
    get_all_meeting_types(user_id)
  end

  @doc """
  Gets a meeting type by ID, raising if not found.
  """
  @spec get_meeting_type!(integer()) :: Ecto.Schema.t()
  def get_meeting_type!(id) do
    MeetingTypeQueries.get_meeting_type!(id)
  end

  @doc """
  Creates a meeting type from form parameters with validation.
  """
  @spec create_meeting_type_from_form(integer(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_meeting_type_from_form(user_id, form_params, ui_state) do
    with {:ok, attrs} <- build_meeting_type_attrs(form_params, ui_state),
         :ok <- gate_custom_fields_change(user_id, attrs),
         :ok <- gate_payment_change(user_id, attrs),
         :ok <- validate_video_integration(attrs, user_id),
         :ok <- validate_calendar_integration(attrs, user_id) do
      create_meeting_type(Map.put(attrs, :user_id, user_id), payment_opts(user_id))
    end
  end

  @doc """
  Updates a meeting type from form parameters with validation.
  """
  @spec update_meeting_type_from_form(Ecto.Schema.t(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_meeting_type_from_form(meeting_type, form_params, ui_state) do
    with {:ok, attrs} <- build_meeting_type_attrs(form_params, ui_state),
         :ok <- gate_custom_fields_change(meeting_type.user_id, attrs),
         :ok <- gate_payment_change(meeting_type.user_id, attrs),
         :ok <- validate_video_integration(attrs, meeting_type.user_id),
         :ok <- validate_calendar_integration(attrs, meeting_type.user_id) do
      update_meeting_type(meeting_type, attrs, payment_opts(meeting_type.user_id))
    end
  end

  @doc """
  Creates default meeting types for a new user.
  Fetches the user's primary calendar integration, builds default templates,
  deduplicates against existing names, then bulk-inserts.
  """
  @spec create_default_meeting_types(integer()) ::
          {:ok, [MeetingTypeSchema.t()]} | {:error, term()}
  def create_default_meeting_types(user_id) when is_integer(user_id) do
    {calendar_integration_id, target_calendar_id} = resolve_primary_calendar(user_id)
    existing = MeetingTypeQueries.existing_names(user_id)
    now = NaiveDateTime.utc_now(:second)

    user_id
    |> default_meeting_type_templates(calendar_integration_id, target_calendar_id, now)
    |> Enum.reject(fn type -> MapSet.member?(existing, type.name) end)
    |> MeetingTypeQueries.bulk_insert_meeting_types()
  end

  @spec create_default_meeting_types(term()) :: {:error, :invalid_user_id}
  def create_default_meeting_types(_invalid_user_id), do: {:error, :invalid_user_id}

  # Private functions

  defp resolve_primary_calendar(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, %{default_booking_calendar_id: cal_id} = integration}
      when is_binary(cal_id) ->
        {integration.id, cal_id}

      _other ->
        {nil, nil}
    end
  end

  defp default_meeting_type_templates(
         user_id,
         calendar_integration_id,
         target_calendar_id,
         now
       ) do
    [
      %{
        user_id: user_id,
        name: "15 Minutes",
        description: "Quick chat or brief consultation",
        duration_minutes: 15,
        icon: "hero-bolt",
        sort_order: 0,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      },
      %{
        user_id: user_id,
        name: "30 Minutes",
        description: "In-depth discussion or detailed review",
        duration_minutes: 30,
        icon: "hero-rocket-launch",
        sort_order: 1,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      }
    ]
  end

  defp build_meeting_type_attrs(params, ui_state) do
    video_integration_id =
      if ui_state.meeting_mode == "video" do
        ui_state.selected_video_integration_id
      else
        nil
      end

    payment_required = params["payment_required"] == "true"

    with {:ok, reminder_config} <- normalize_reminder_config_params(params["reminder_config"]),
         {:ok, price_cents} <- parse_price_cents(payment_required, params["price"]) do
      attrs = %{
        name: params["name"],
        duration_minutes: String.to_integer(params["duration"]),
        description: params["description"],
        icon: ui_state.selected_icon,
        is_active: params["is_active"] == "true",
        allow_video: ui_state.meeting_mode == "video",
        allow_guests: params["allow_guests"] == "true",
        video_integration_id: video_integration_id,
        calendar_integration_id: blank_to_nil(params["calendar_integration_id"]),
        target_calendar_id: blank_to_nil(params["target_calendar_id"]),
        reminder_config: reminder_config,
        payment_required: payment_required,
        price_cents: price_cents
      }

      attrs =
        if Map.has_key?(params, "custom_fields") do
          Map.put(attrs, :custom_fields, params["custom_fields"])
        else
          attrs
        end

      {:ok, attrs}
    end
  rescue
    ArgumentError ->
      {:error, :invalid_duration}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Builds the payment-validation opts the schema changeset needs. The
  # schema must not reach into the payments domain itself (layering), so
  # the context resolves the host's charge capability, default currency,
  # and the per-currency minimum here and threads them in as opts.
  defp payment_opts(user_id) do
    currency = host_currency(user_id)

    [
      host_charges_enabled: MeetingPayments.charges_enabled_for_user?(user_id),
      currency: currency,
      currency_minimum_cents: MeetingPayments.currency_minimum_cents(currency)
    ]
  end

  # The host's pricing currency is their Connect account's default
  # currency. When no account exists yet, fall back to the first entry of
  # the currency allowlist (defaulting to "usd"), matching the default the
  # payments dashboard surfaces.
  defp host_currency(user_id) do
    case MeetingPayments.get_connect_account_for_user(user_id) do
      %{default_currency: currency} when is_binary(currency) and currency != "" ->
        currency

      _other ->
        List.first(MeetingPayments.currency_allowlist()) || "usd"
    end
  end

  # Converts the major-unit price string from the form into integer cents.
  # When payment is not required the price is irrelevant and stored as nil.
  # Bad input yields `{:error, :invalid_price}` so the form surfaces it the
  # same way an invalid duration does.
  defp parse_price_cents(false, _price), do: {:ok, nil}
  defp parse_price_cents(true, nil), do: {:ok, nil}
  defp parse_price_cents(true, ""), do: {:ok, nil}

  defp parse_price_cents(true, price) when is_binary(price) do
    case Decimal.parse(String.trim(price)) do
      {decimal, ""} ->
        cents =
          decimal
          |> Decimal.mult(100)
          |> Decimal.round(0)
          |> Decimal.to_integer()

        {:ok, cents}

      _invalid ->
        {:error, :invalid_price}
    end
  end

  defp parse_price_cents(true, _price), do: {:error, :invalid_price}

  # Custom booking questions are gated behind the :custom_questions_allowed
  # feature flag. Core's default checker always allows access, so self-hosted
  # deployments are unaffected; SaaS overrides this to require a Pro plan.
  # Only writes that would add or modify a non-empty question list are gated —
  # an absent or empty list (the no-questions path) is always allowed.
  defp gate_custom_fields_change(user_id, attrs) do
    case Map.get(attrs, :custom_fields) do
      nil -> :ok
      fields when fields == [] or fields == %{} -> :ok
      _non_empty -> Features.check_access(user_id, :custom_questions_allowed)
    end
  end

  # Paid meeting types are gated behind the :meeting_payments feature. The form
  # hides the price controls when the host lacks access, but a forged save with
  # `payment_required=true` must not slip a paid type through — and on SaaS it
  # must not bypass the Pro-plan requirement. Only a write that *enables*
  # payment is gated; turning payment off is always allowed so a downgraded
  # host can still disable a previously paid type.
  #
  # `:stripe_required` is treated as allowed at this layer: the host has the
  # plan but no charges-enabled Connect account yet. The schema changeset
  # (driven by `payment_opts/1`'s `host_charges_enabled`) is the authority on
  # whether a price may actually be persisted without a live account.
  defp gate_payment_change(user_id, %{payment_required: true}) do
    case Features.check_access(user_id, :meeting_payments) do
      :ok -> :ok
      {:error, :stripe_required} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp gate_payment_change(_user_id, _attrs), do: :ok

  defp validate_video_integration(%{allow_video: true, video_integration_id: nil}, _user_id) do
    {:error, :video_integration_required}
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: ""}, _user_id),
    do: {:error, :video_integration_required}

  defp validate_video_integration(%{allow_video: true, video_integration_id: id}, user_id)
       when is_integer(id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, %{is_active: true}} -> :ok
      {:ok, _integration} -> {:error, :invalid_video_integration}
      {:error, :not_found} -> {:error, :invalid_video_integration}
    end
  end

  defp validate_video_integration(_attrs, _user_id), do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: nil, target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(%{calendar_integration_id: nil}, _user_id),
    do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: _target},
         _user_id
       ),
       do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: id, target_calendar_id: target_calendar_id},
         user_id
       )
       when is_integer(id) do
    with {:ok, integration} <- CalendarManagement.fetch_integration_for_user(id, user_id),
         :ok <- validate_target_calendar(target_calendar_id, integration) do
      :ok
    else
      {:error, :not_found} -> {:error, :calendar_integration_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp validate_calendar_integration(%{calendar_integration_id: id}, _user_id)
       when is_binary(id) and id != "" do
    {:error, :calendar_integration_invalid}
  end

  defp validate_calendar_integration(_other_attrs, _user_id), do: :ok

  defp validate_target_calendar(nil, _calendar_integration),
    do: {:error, :target_calendar_required}

  defp validate_target_calendar("", _calendar_integration),
    do: {:error, :target_calendar_required}

  defp validate_target_calendar(target_calendar_id, integration) do
    calendar_list = integration.calendar_list

    if calendar_list == [] do
      :ok
    else
      found? =
        Enum.any?(calendar_list, fn cal ->
          UriUtils.uri_safe_match?(cal["id"] || cal[:id], target_calendar_id)
        end)

      if found? do
        :ok
      else
        {:error, :target_calendar_invalid}
      end
    end
  end

  defp normalize_reminder_config_params(nil), do: {:ok, nil}
  defp normalize_reminder_config_params(""), do: {:ok, nil}

  defp normalize_reminder_config_params(reminders) when is_list(reminders) do
    normalized = Enum.map(reminders, &ReminderUtils.normalize_reminder_string_keys/1)

    if Enum.any?(normalized, &match?({:error, _error_reason}, &1)) do
      {:error, :invalid_reminder_config}
    else
      {:ok, Enum.map(normalized, fn {:ok, reminder} -> reminder end)}
    end
  end

  defp normalize_reminder_config_params(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> normalize_reminder_config_params()
  end

  defp normalize_reminder_config_params(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> normalize_reminder_config_params(decoded)
      {:error, _decode_error} -> {:error, :invalid_reminder_config}
    end
  end

  defp normalize_reminder_config_params(_other), do: {:error, :invalid_reminder_config}
end

defmodule Tymeslot.MeetingTypes.FormMapper do
  @moduledoc """
  Turns meeting-type form input into schema attributes.

  The form speaks in strings and UI state: a duration typed as text, a price in
  major units, reminders that arrive as a list, a map or a JSON string
  depending on how the client serialised them, and a meeting mode that decides
  whether a video integration applies at all. The schema wants integers, cents
  and normalised structs. Everything needed to get from one to the other lives
  here, so the context can compose a save without also owning the vocabulary of
  a particular form.

  Money is the reason this is worth isolating. `parse_price_cents/2` is the
  single conversion from a typed price to the integer minor units that reach
  Stripe; a second copy of that arithmetic elsewhere is exactly the kind of
  drift that produces a charge off by a factor of a hundred.
  """

  alias Tymeslot.MeetingPayments
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Validation.Constraints

  @typedoc "Why form input could not be mapped onto schema attributes."
  @type error :: :invalid_duration | :invalid_price | :invalid_reminder_config

  @doc """
  Builds schema attributes from raw form params and the form's UI state.

  `custom_fields` is only included when the params carry the key, so a form
  that does not render the questions editor cannot blank an existing question
  list by omission.
  """
  @spec build_attrs(map(), map()) :: {:ok, map()} | {:error, error()}
  def build_attrs(params, ui_state) do
    payment_required = params["payment_required"] == "true"

    with {:ok, duration_minutes} <- parse_duration(params["duration"]),
         {:ok, reminder_config} <- normalize_reminder_config(params["reminder_config"]),
         {:ok, price_cents} <- parse_price_cents(payment_required, params["price"]) do
      attrs = %{
        name: params["name"],
        duration_minutes: duration_minutes,
        slot_interval_minutes: parse_optional_interval(params["slot_interval"]),
        description: params["description"],
        icon: ui_state.selected_icon,
        is_active: params["is_active"] == "true",
        allow_video: ui_state.meeting_mode == "video",
        allow_guests: params["allow_guests"] == "true",
        video_integration_id: video_integration_id(ui_state),
        calendar_integration_id: blank_to_nil(params["calendar_integration_id"]),
        availability_schedule_id: blank_to_nil(params["availability_schedule_id"]),
        target_calendar_id: blank_to_nil(params["target_calendar_id"]),
        reminder_config: reminder_config,
        payment_required: payment_required,
        price_cents: price_cents
      }

      attrs = Map.merge(attrs, booking_limits(params))

      {:ok, maybe_put_custom_fields(attrs, params)}
    end
  end

  @doc """
  Builds the payment-validation opts the schema changeset needs.

  The schema must not reach into the payments domain itself, so the host's
  charge capability, default currency, and the per-currency minimum are
  resolved here and threaded in as opts.
  """
  @spec payment_opts(integer()) :: keyword()
  def payment_opts(user_id) do
    currency = host_currency(user_id)

    [
      host_charges_enabled: MeetingPayments.charges_enabled_for_user?(user_id),
      currency: currency,
      currency_minimum_cents: MeetingPayments.currency_minimum_cents(currency)
    ]
  end

  defp video_integration_id(%{meeting_mode: "video"} = ui_state),
    do: ui_state.selected_video_integration_id

  defp video_integration_id(_ui_state), do: nil

  defp maybe_put_custom_fields(attrs, params) do
    if Map.has_key?(params, "custom_fields") do
      Map.put(attrs, :custom_fields, params["custom_fields"])
    else
      attrs
    end
  end

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {duration, ""} -> {:ok, duration}
      _other -> {:error, :invalid_duration}
    end
  end

  defp parse_duration(_value), do: {:error, :invalid_duration}

  # Blank means "use the meeting type's own duration"; out-of-range values are
  # left to the changeset.
  defp parse_optional_interval(value) when is_integer(value), do: value

  defp parse_optional_interval(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {interval, ""} -> interval
      _other -> nil
    end
  end

  defp parse_optional_interval(_value), do: nil

  defp booking_limits(params) do
    Map.new(Constraints.booking_limit_fields(), fn field ->
      {field, parse_booking_limit(params[Atom.to_string(field)])}
    end)
  end

  # Blank means no limit; out-of-range values are left to the changeset.
  defp parse_booking_limit(value) when is_integer(value), do: value

  defp parse_booking_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} -> limit
      _other -> nil
    end
  end

  defp parse_booking_limit(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # The host's pricing currency is their Connect account's default currency.
  # When no account exists yet, fall back to the first entry of the currency
  # allowlist (defaulting to "usd"), matching the default the payments
  # dashboard surfaces.
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

  defp normalize_reminder_config(nil), do: {:ok, nil}
  defp normalize_reminder_config(""), do: {:ok, nil}

  defp normalize_reminder_config(reminders) when is_list(reminders) do
    normalized = Enum.map(reminders, &ReminderUtils.normalize_reminder_string_keys/1)

    if Enum.any?(normalized, &match?({:error, _error_reason}, &1)) do
      {:error, :invalid_reminder_config}
    else
      {:ok, Enum.map(normalized, fn {:ok, reminder} -> reminder end)}
    end
  end

  defp normalize_reminder_config(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> normalize_reminder_config()
  end

  defp normalize_reminder_config(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> normalize_reminder_config(decoded)
      {:error, _decode_error} -> {:error, :invalid_reminder_config}
    end
  end

  defp normalize_reminder_config(_other), do: {:error, :invalid_reminder_config}
end
